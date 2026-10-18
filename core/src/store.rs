//! SQLite store: canonical event log plus the `blocks` projection.

use std::collections::{BTreeSet, HashMap};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{params, Connection, OptionalExtension, Row, Transaction, TransactionBehavior};

use crate::reducer::{fold, State};
use crate::stats;
use crate::types::*;
use crate::validity::*;

const MIGRATION_0001: &str = include_str!("../../spec/migrations/0001_init.sql");
const MIGRATION_0002: &str = include_str!("../../spec/migrations/0002_peers.sql");

/// Migrations in order; each runs in the transaction that bumps `meta.schema_version`.
const MIGRATIONS: [(i64, &str); 2] = [(1, MIGRATION_0001), (2, MIGRATION_0002)];
/// Newest schema version this build understands.
const SCHEMA_VERSION: i64 = 2;

/// Owned form of [`EventKey`].
type OwnedKey = (i64, u32, String, u64);

fn owned_key(e: &Event) -> OwnedKey {
    (e.hlc_ms, e.hlc_counter, e.device_id.clone(), e.seq)
}

type Clock = Box<dyn Fn() -> i64 + Send + Sync>;

fn system_now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

/// One Device's store. Holds the cached fold of the log; keeps `blocks` equal to it.
pub struct Store {
    conn: Connection,
    device_id: String,
    config: Config,
    state: State,
    /// Greatest event position stored.
    last_key: Option<OwnedKey>,
    /// Wall clock used to reject far-future events from peers (see [`Store::set_clock`]).
    clock: Clock,
}

fn new_uuid() -> String {
    let mut b: [u8; 16] = rand::random();
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h: String = b.iter().map(|x| format!("{x:02x}")).collect();
    format!("{}-{}-{}-{}-{}", &h[..8], &h[8..12], &h[12..16], &h[16..20], &h[20..])
}

fn row_to_event(r: &Row<'_>) -> rusqlite::Result<Event> {
    let bad = |i: usize, m: String| {
        rusqlite::Error::FromSqlConversionFailure(i, rusqlite::types::Type::Text, m.into())
    };
    let payload: String = r.get(6)?;
    let source: String = r.get(7)?;
    Ok(Event {
        id: r.get(0)?,
        device_id: r.get(1)?,
        seq: r.get::<_, i64>(2)? as u64,
        hlc_ms: r.get(3)?,
        hlc_counter: r.get::<_, i64>(4)? as u32,
        ty: r.get(5)?,
        payload: serde_json::from_str(&payload).map_err(|e| bad(6, e.to_string()))?,
        source: Source::parse(&source).ok_or_else(|| bad(7, format!("invalid source {source:?}")))?,
        command_key: r.get(8)?,
    })
}

const EVENT_COLS: &str = "id, device_id, seq, hlc_ms, hlc_counter, type, payload, source, command_key";

fn row_to_block(r: &Row<'_>) -> rusqlite::Result<Block> {
    let bad = |i: usize, m: String| {
        rusqlite::Error::FromSqlConversionFailure(i, rusqlite::types::Type::Text, m.into())
    };
    let kind: String = r.get(1)?;
    let source: String = r.get(4)?;
    let phase: String = r.get(9)?;
    let outcome: Option<String> = r.get(11)?;
    Ok(Block {
        id: r.get(0)?,
        kind: Kind::parse(&kind).ok_or_else(|| bad(1, kind.clone()))?,
        label: r.get(2)?,
        project: r.get(3)?,
        source: Source::parse(&source).ok_or_else(|| bad(4, source.clone()))?,
        device_id: r.get(5)?,
        started_ms: r.get(6)?,
        planned_ms: r.get(7)?,
        elapsed_ms: r.get(8)?,
        phase: Phase::parse(&phase).ok_or_else(|| bad(9, phase.clone()))?,
        phase_since_ms: r.get(10)?,
        outcome: match outcome {
            None => None,
            Some(o) => Some(Outcome::parse(&o).ok_or_else(|| bad(11, o.clone()))?),
        },
        ended_ms: r.get(12)?,
    })
}

const BLOCK_COLS: &str =
    "id, kind, label, project, source, device_id, started_ms, planned_ms, elapsed_ms, phase, phase_since_ms, outcome, ended_ms";

fn put_block(tx: &Transaction<'_>, b: &Block) -> rusqlite::Result<()> {
    tx.execute(
        &format!("INSERT OR REPLACE INTO blocks ({BLOCK_COLS}) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)"),
        params![
            b.id,
            b.kind.as_str(),
            b.label,
            b.project,
            b.source.to_string(),
            b.device_id,
            b.started_ms,
            b.planned_ms,
            b.elapsed_ms,
            b.phase.as_str(),
            b.phase_since_ms,
            b.outcome.map(Outcome::as_str),
            b.ended_ms,
        ],
    )?;
    Ok(())
}

fn load_events(conn: &Connection) -> Result<Vec<Event>> {
    let mut st = conn.prepare(&format!(
        "SELECT {EVENT_COLS} FROM events ORDER BY hlc_ms, hlc_counter, device_id, seq"
    ))?;
    let rows = st.query_map([], row_to_event)?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

fn row_to_device(r: &Row<'_>) -> rusqlite::Result<Device> {
    Ok(Device { device_id: r.get(0)?, name: r.get(1)?, paired: r.get(2)?, revoked: r.get(3)? })
}

fn check_device_id(id: &str) -> Result<()> {
    if id.is_empty() {
        return Err(Error::InvalidArgument("empty device_id".into()));
    }
    Ok(())
}

/// What the validity and clock checks decided about one ingested event.
enum Verdict {
    Ok,
    Invalid(String),
    Future,
}

/// Reads `meta.schema_version` strictly. `None` when the store has no `meta` table yet.
fn stored_schema_version(tx: &Transaction<'_>) -> Result<Option<i64>> {
    let has_meta: bool = tx.query_row(
        "SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE type='table' AND name='meta')",
        [],
        |r| r.get(0),
    )?;
    if !has_meta {
        return Ok(None);
    }
    let text: Option<String> = tx
        .query_row("SELECT value FROM meta WHERE key='schema_version'", [], |r| r.get(0))
        .optional()?;
    let text = text.ok_or_else(|| Error::InvalidState("store metadata is damaged: no schema_version".into()))?;
    text.parse::<i64>()
        .ok()
        .filter(|v| *v >= 1)
        .map(Some)
        .ok_or_else(|| Error::InvalidState(format!("store metadata is damaged: schema_version {text:?}")))
}

impl Store {
    /// Opens or creates the store at `path` for `device_id` with default [`Config`].
    pub fn open(path: impl AsRef<Path>, device_id: &str) -> Result<Store> {
        Store::open_with(path, device_id, Config::default())
    }

    /// Opens an in-memory store with default [`Config`].
    pub fn open_in_memory(device_id: &str) -> Result<Store> {
        Store::open_in_memory_with(device_id, Config::default())
    }

    pub fn open_with(path: impl AsRef<Path>, device_id: &str, config: Config) -> Result<Store> {
        Store::init(Connection::open(path)?, device_id, config)
    }

    pub fn open_in_memory_with(device_id: &str, config: Config) -> Result<Store> {
        Store::init(Connection::open_in_memory()?, device_id, config)
    }

    fn init(mut conn: Connection, device_id: &str, config: Config) -> Result<Store> {
        if device_id.is_empty() {
            return Err(Error::InvalidArgument("empty device_id".into()));
        }
        if device_id.len() > MAX_ID_BYTES {
            return Err(Error::InvalidArgument(format!("device_id longer than {MAX_ID_BYTES} bytes")));
        }
        conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")?;
        // First open and every migration run in one transaction with the version bump, so a
        // crash leaves either the old store or the new one, never a half-initialised file.
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let version = match stored_schema_version(&tx)? {
            None => 0,
            Some(v) if v > SCHEMA_VERSION => {
                return Err(Error::InvalidState(format!(
                    "this store uses schema version {v}, newer than the version {SCHEMA_VERSION} this build supports; upgrade Pomo"
                )));
            }
            Some(v) => {
                let stored: Option<String> = tx
                    .query_row("SELECT value FROM meta WHERE key='device_id'", [], |r| r.get(0))
                    .optional()?;
                let stored =
                    stored.ok_or_else(|| Error::InvalidState("store metadata is damaged: no device_id".into()))?;
                if stored != device_id {
                    return Err(Error::DeviceMismatch { stored, requested: device_id.to_string() });
                }
                v
            }
        };
        for (v, sql) in MIGRATIONS {
            if v <= version {
                continue;
            }
            tx.execute_batch(sql)?;
            if v == 1 {
                tx.execute(
                    "INSERT INTO meta (key, value) VALUES ('schema_version', '1'), ('device_id', ?1)",
                    [device_id],
                )?;
            }
            tx.execute("UPDATE meta SET value = ?1 WHERE key = 'schema_version'", [v.to_string()])?;
        }
        tx.execute("INSERT OR IGNORE INTO devices (device_id) VALUES (?1)", [device_id])?;
        tx.commit()?;
        let mut s = Store {
            conn,
            device_id: device_id.to_string(),
            config,
            state: State::new(config),
            last_key: None,
            clock: Box::new(system_now_ms),
        };
        s.rebuild_projections()?;
        Ok(s)
    }

    /// This store's device id.
    pub fn device_id(&self) -> &str {
        &self.device_id
    }

    /// Replaces the wall clock (ms since the epoch) that ingest compares peer events against.
    /// The default is the system clock; tests inject a fixed or moving one. Command issuing
    /// takes its time from the `now_ms` argument of [`Store::apply`], not from this clock.
    pub fn set_clock(&mut self, clock: impl Fn() -> i64 + Send + Sync + 'static) {
        self.clock = Box::new(clock);
    }

    /// Refolds the whole log and rewrites the `blocks` table.
    pub fn rebuild_projections(&mut self) -> Result<()> {
        let tx = self.conn.transaction()?;
        let events = load_events(&tx)?;
        let mut state = fold(&events, self.config);
        state.take_dirty();
        tx.execute("DELETE FROM blocks", [])?;
        for b in state.blocks_sorted() {
            put_block(&tx, &b)?;
        }
        tx.commit()?;
        self.last_key = events.last().map(owned_key);
        self.state = state;
        Ok(())
    }

    /// Stores new events, idempotent by `id`. `(device_id, seq)` / `(device_id, command_key)`
    /// collisions with a different id are rejected into the report and not stored; the rest of
    /// the call is stored. Events failing [`validate_event`] are rejected into `invalid`, events
    /// more than a day ahead of this Device's clock are skipped into `future`; in both cases
    /// later events of the same Device in the call are skipped too, so the log never gets a
    /// `seq` hole. Updates the projection.
    pub fn ingest(&mut self, events: &[Event]) -> Result<IngestReport> {
        self.ingest_with(events, false, false)
    }

    /// Like [`Store::ingest`], but all-or-nothing: when any event collides with a stored one
    /// under a different id (or with another event of the same call), returns
    /// [`Error::Conflict`]; when any event fails [`validate_event`], returns
    /// [`Error::InvalidArgument`]. Either way nothing is stored. Far-future events are skipped
    /// as in [`Store::ingest`].
    pub fn ingest_atomic(&mut self, events: &[Event]) -> Result<IngestReport> {
        self.ingest_with(events, true, false)
    }

    fn ingest_with(&mut self, events: &[Event], atomic: bool, local: bool) -> Result<IngestReport> {
        match self.ingest_inner(events, atomic, local) {
            Ok(r) => Ok(r),
            Err(e) => {
                // A conflict or an invalid event returns before the cached state changes;
                // anything else may leave it ahead of the rolled-back transaction.
                if !matches!(e, Error::Conflict(_) | Error::InvalidArgument(_)) {
                    let _ = self.rebuild_projections();
                }
                Err(e)
            }
        }
    }

    fn ingest_inner(&mut self, events: &[Event], atomic: bool, local: bool) -> Result<IngestReport> {
        let mut report = IngestReport::default();
        let horizon = (self.clock)().saturating_add(MAX_FUTURE_SKEW_MS);
        let mut verdicts: Vec<Verdict> = Vec::with_capacity(events.len());
        // Per Device: lowest `seq` of an event that will not be stored, and whether it is a
        // future event (else invalid). Later seqs of that Device are skipped too.
        let mut stop: HashMap<&str, (u64, bool)> = HashMap::new();
        for e in events {
            let v = match validate_event(e) {
                Err(why) if atomic => {
                    return Err(Error::InvalidArgument(format!("event {:.40}: {why}", e.id)));
                }
                Err(why) => Verdict::Invalid(why),
                Ok(()) if !local && e.hlc_ms > horizon => Verdict::Future,
                Ok(()) => Verdict::Ok,
            };
            if !matches!(v, Verdict::Ok) {
                let future = matches!(v, Verdict::Future);
                let slot = stop.entry(&e.device_id).or_insert((e.seq, future));
                if e.seq < slot.0 {
                    *slot = (e.seq, future);
                }
            }
            verdicts.push(v);
        }

        let tx = self.conn.transaction()?;
        let mut fresh: Vec<&Event> = Vec::new();
        for (e, verdict) in events.iter().zip(&verdicts) {
            match verdict {
                Verdict::Invalid(why) => {
                    report.invalid.push(Rejected { id: e.id.clone(), reason: why.clone() });
                    continue;
                }
                Verdict::Future => {
                    report.future.push(Rejected {
                        id: e.id.clone(),
                        reason: format!("hlc_ms {} is more than a day ahead of this clock", e.hlc_ms),
                    });
                    continue;
                }
                Verdict::Ok => {}
            }
            if let Some(&(at, future)) = stop.get(e.device_id.as_str()) {
                if e.seq > at {
                    let r = Rejected {
                        id: e.id.clone(),
                        reason: format!("follows the rejected event {} of {}", at, e.device_id),
                    };
                    if future {
                        report.future.push(r);
                    } else {
                        report.invalid.push(r);
                    }
                    continue;
                }
            }
            let id_exists: bool =
                tx.query_row("SELECT EXISTS (SELECT 1 FROM events WHERE id = ?1)", [&e.id], |r| r.get(0))?;
            if id_exists {
                report.duplicates += 1;
                continue;
            }
            let seq_taken: bool = tx.query_row(
                "SELECT EXISTS (SELECT 1 FROM events WHERE device_id = ?1 AND seq = ?2)",
                params![e.device_id, e.seq as i64],
                |r| r.get(0),
            )?;
            if seq_taken {
                let reason = format!("({}, {}) already stored with a different id", e.device_id, e.seq);
                if atomic {
                    return Err(Error::Conflict(reason));
                }
                report.conflicts.push(Rejected { id: e.id.clone(), reason });
                continue;
            }
            if let Some(k) = &e.command_key {
                let key_taken: bool = tx.query_row(
                    "SELECT EXISTS (SELECT 1 FROM events WHERE device_id = ?1 AND command_key = ?2)",
                    params![e.device_id, k],
                    |r| r.get(0),
                )?;
                if key_taken {
                    let reason = format!("command_key {k:?} of {} already used by another event", e.device_id);
                    if atomic {
                        return Err(Error::Conflict(reason));
                    }
                    report.conflicts.push(Rejected { id: e.id.clone(), reason });
                    continue;
                }
            }
            tx.execute(
                &format!("INSERT INTO events ({EVENT_COLS}) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)"),
                params![
                    e.id,
                    e.device_id,
                    e.seq as i64,
                    e.hlc_ms,
                    i64::from(e.hlc_counter),
                    e.ty,
                    serde_json::to_string(&e.payload)?,
                    e.source.to_string(),
                    e.command_key,
                ],
            )?;
            tx.execute("INSERT OR IGNORE INTO devices (device_id) VALUES (?1)", [&e.device_id])?;
            report.inserted += 1;
            fresh.push(e);
        }
        if fresh.is_empty() {
            return Ok(report);
        }
        fresh.sort_by(|a, b| a.key().cmp(&b.key()));
        let in_order = match &self.last_key {
            None => true,
            Some(l) => {
                let first = fresh[0].key();
                (l.0, l.1, l.2.as_str(), l.3) < first
            }
        };
        let new_last = owned_key(fresh[fresh.len() - 1]);
        if in_order {
            for e in &fresh {
                self.state.apply(e);
            }
            for id in self.state.take_dirty() {
                if let Some(b) = self.state.block(&id) {
                    put_block(&tx, b)?;
                }
            }
        } else {
            let all = load_events(&tx)?;
            let mut state = fold(&all, self.config);
            state.take_dirty();
            tx.execute("DELETE FROM blocks", [])?;
            for b in state.blocks_sorted() {
                put_block(&tx, &b)?;
            }
            self.state = state;
        }
        tx.commit()?;
        if self.last_key.as_ref().is_none_or(|l| *l < new_last) {
            self.last_key = Some(new_last);
        }
        Ok(report)
    }

    /// Validates `cmd` against the state at the new event's time and issues exactly one event
    /// (HLC rule, per-device `seq`). A used `command_key` returns the original event and writes
    /// nothing. The issued event must satisfy [`validate_event`], else
    /// [`Error::InvalidArgument`].
    pub fn apply(&mut self, cmd: Command, source: Source, now_ms: i64) -> Result<Event> {
        if let Some(k) = &cmd.command_key {
            let prev = self
                .conn
                .query_row(
                    &format!("SELECT {EVENT_COLS} FROM events WHERE device_id = ?1 AND command_key = ?2"),
                    params![self.device_id, k],
                    row_to_event,
                )
                .optional()?;
            if let Some(e) = prev {
                return Ok(e);
            }
        }
        let (hlc_ms, hlc_counter) = match &self.last_key {
            Some(l) if now_ms <= l.0 => {
                if l.1 >= MAX_HLC_COUNTER {
                    (l.0.saturating_add(1), 0)
                } else {
                    (l.0, l.1 + 1)
                }
            }
            _ => (now_ms, 0),
        };
        let (timer, blocks) = self.state.at(hlc_ms);
        let live = timer.block_id.clone();
        let duration_error = |name: &str| {
            Error::InvalidArgument(format!("{name} must be in {MIN_DURATION_MS}..={MAX_DURATION_MS} (24 h)"))
        };
        let payload = match cmd.body {
            CommandBody::Start { kind, planned_ms, label, project } => {
                if !duration_in_bounds(planned_ms) {
                    return Err(duration_error("planned_ms"));
                }
                Payload::Started { block_id: new_uuid(), kind, planned_ms, label, project }
            }
            CommandBody::Pause => match (timer.status, live) {
                (TimerStatus::Running, Some(block_id)) => Payload::Paused { block_id },
                _ => return Err(Error::InvalidState("no running block to pause".into())),
            },
            CommandBody::Resume => match (timer.status, live) {
                (TimerStatus::Paused, Some(block_id)) => Payload::Resumed { block_id },
                _ => return Err(Error::InvalidState("no paused block to resume".into())),
            },
            CommandBody::Extend { add_ms } => {
                if !duration_in_bounds(add_ms) {
                    return Err(duration_error("add_ms"));
                }
                match live {
                    Some(block_id) => {
                        // The reducer would ignore an extend past the cap; say so instead of
                        // writing an event that does nothing.
                        let planned = blocks.iter().find(|b| b.id == block_id).map_or(0, |b| b.planned_ms);
                        if planned.saturating_add(add_ms) > MAX_BLOCK_PLANNED_MS {
                            return Err(Error::InvalidArgument(format!(
                                "a block cannot be longer than {} hours in total",
                                MAX_BLOCK_PLANNED_MS / 3_600_000
                            )));
                        }
                        Payload::Extended { block_id, add_ms }
                    }
                    None => return Err(Error::InvalidState("no live block to extend".into())),
                }
            }
            CommandBody::Skip => match live {
                Some(block_id) => Payload::Skipped { block_id },
                None => return Err(Error::InvalidState("no live block to skip".into())),
            },
            CommandBody::Stop => match live {
                Some(block_id) => Payload::Stopped { block_id },
                None => return Err(Error::InvalidState("no live block to stop".into())),
            },
            CommandBody::Reset => match live {
                Some(block_id) => Payload::Reset { block_id },
                None => return Err(Error::InvalidState("no live block to reset".into())),
            },
            CommandBody::Label { block_id, label, project } => {
                let target = match block_id.or(live) {
                    Some(id) => id,
                    None => blocks
                        .last()
                        .map(|b| b.id.clone())
                        .ok_or_else(|| Error::InvalidState("no block to label".into()))?,
                };
                if !blocks.iter().any(|b| b.id == target) {
                    return Err(Error::NotFound(format!("unknown block {target}")));
                }
                Payload::Labeled { block_id: target, label: Some(label), project }
            }
        };
        let seq: i64 = self.conn.query_row(
            "SELECT COALESCE(MAX(seq), 0) FROM events WHERE device_id = ?1",
            [&self.device_id],
            |r| r.get(0),
        )?;
        let (ty, payload) = payload.to_parts();
        let ev = Event {
            id: new_uuid(),
            device_id: self.device_id.clone(),
            seq: seq as u64 + 1,
            hlc_ms,
            hlc_counter,
            ty: ty.to_string(),
            payload,
            source,
            command_key: cmd.command_key,
        };
        validate_event(&ev).map_err(Error::InvalidArgument)?;
        let report = self.ingest_with(std::slice::from_ref(&ev), false, true)?;
        if report.inserted != 1 {
            return Err(Error::Conflict(format!("event rejected: {report:?}")));
        }
        Ok(ev)
    }

    /// The Device `device_id`, if known.
    pub fn device(&self, device_id: &str) -> Result<Option<Device>> {
        Ok(self
            .conn
            .query_row(
                "SELECT device_id, name, paired, revoked FROM devices WHERE device_id = ?1",
                [device_id],
                row_to_device,
            )
            .optional()?)
    }

    /// Every known Device, own included, ordered by `device_id`.
    pub fn devices(&self) -> Result<Vec<Device>> {
        let mut st = self.conn.prepare("SELECT device_id, name, paired, revoked FROM devices ORDER BY device_id")?;
        let rows = st.query_map([], row_to_device)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Records `device_id` (when new) and sets its name. Trust flags are untouched.
    pub fn upsert_device(&mut self, device_id: &str, name: &str) -> Result<()> {
        check_device_id(device_id)?;
        self.conn.execute(
            "INSERT INTO devices (device_id, name) VALUES (?1, ?2)
             ON CONFLICT (device_id) DO UPDATE SET name = ?2",
            params![device_id, name],
        )?;
        Ok(())
    }

    /// Sets the local `paired` flag, recording the Device when new. Independent of `revoked`.
    pub fn set_device_paired(&mut self, device_id: &str, paired: bool) -> Result<()> {
        check_device_id(device_id)?;
        self.conn.execute(
            "INSERT INTO devices (device_id, paired) VALUES (?1, ?2)
             ON CONFLICT (device_id) DO UPDATE SET paired = ?2",
            params![device_id, paired],
        )?;
        Ok(())
    }

    /// Sets the local `revoked` flag, recording the Device when new. Independent of `paired`.
    pub fn set_device_revoked(&mut self, device_id: &str, revoked: bool) -> Result<()> {
        check_device_id(device_id)?;
        self.conn.execute(
            "INSERT INTO devices (device_id, revoked) VALUES (?1, ?2)
             ON CONFLICT (device_id) DO UPDATE SET revoked = ?2",
            params![device_id, revoked],
        )?;
        Ok(())
    }

    /// Last known address (an opaque string, e.g. an iroh endpoint ticket) of a peer Device.
    /// Local only: stored in `peers`, never synced.
    pub fn peer_address(&self, device_id: &str) -> Result<Option<String>> {
        Ok(self
            .conn
            .query_row("SELECT address FROM peers WHERE device_id = ?1", [device_id], |r| r.get(0))
            .optional()?)
    }

    /// Remembers `address` as the last known address of `device_id`.
    pub fn set_peer_address(&mut self, device_id: &str, address: &str, now_ms: i64) -> Result<()> {
        check_device_id(device_id)?;
        self.conn.execute(
            "INSERT INTO peers (device_id, address, updated_ms) VALUES (?1, ?2, ?3)
             ON CONFLICT (device_id) DO UPDATE SET address = ?2, updated_ms = ?3",
            params![device_id, address, now_ms],
        )?;
        Ok(())
    }

    /// Per-device max `seq`.
    pub fn version_vector(&self) -> Result<VersionVector> {
        let mut st = self.conn.prepare("SELECT device_id, MAX(seq) FROM events GROUP BY device_id")?;
        let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? as u64)))?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Events the holder of `vv` lacks, ordered by `(device_id, seq)`. Entries of `vv` above
    /// `i64::MAX` are clamped.
    pub fn events_after(&self, vv: &VersionVector) -> Result<Vec<Event>> {
        self.events_after_limit(vv, usize::MAX)
    }

    /// The first `limit` events of [`Store::events_after`], read with a SQL `LIMIT` so a large
    /// log is never loaded whole. Each Device's events come as a prefix of its `seq` run, so
    /// advancing `vv` by what was returned and calling again continues without gaps.
    pub fn events_after_limit(&self, vv: &VersionVector, limit: usize) -> Result<Vec<Event>> {
        let mut out = Vec::new();
        let mut st = self.conn.prepare(&format!(
            "SELECT {EVENT_COLS} FROM events WHERE device_id = ?1 AND seq > ?2 ORDER BY seq LIMIT ?3"
        ))?;
        for (dev, max) in self.version_vector()? {
            let room = limit.saturating_sub(out.len());
            if room == 0 {
                break;
            }
            let have = vv.get(&dev).copied().unwrap_or(0).min(i64::MAX as u64);
            if max > have {
                let room = room.min(i64::MAX as usize) as i64;
                for e in st.query_map(params![dev, have as i64, room], row_to_event)? {
                    out.push(e?);
                }
            }
        }
        Ok(out)
    }

    /// All events in total order.
    pub fn events(&self) -> Result<Vec<Event>> {
        load_events(&self.conn)
    }

    /// The Timer at `now_ms`.
    pub fn timer(&self, now_ms: i64) -> TimerView {
        self.state.at(now_ms).0
    }

    /// Blocks with `started_ms` in `range`, ordered by `(started_ms, id)`, read from the projection and settled at `now_ms`.
    pub fn blocks(&self, range: Range, now_ms: i64) -> Result<Vec<Block>> {
        let mut out = self.projected_blocks(range)?;
        for b in &mut out {
            if let Some(s) = b.settled_at(now_ms) {
                *b = s;
            }
        }
        Ok(out)
    }

    /// The block `id`, settled at `now_ms`; one indexed lookup.
    pub fn block(&self, id: &str, now_ms: i64) -> Result<Option<Block>> {
        let b = self
            .conn
            .query_row(&format!("SELECT {BLOCK_COLS} FROM blocks WHERE id = ?1"), [id], row_to_block)
            .optional()?;
        Ok(b.map(|b| b.settled_at(now_ms).unwrap_or(b)))
    }

    /// Up to `limit` blocks with `started_ms` in `range` (and of `kind`, when given), newest
    /// first by `(started_ms, id)`, settled at `now_ms`. The range, kind and limit are applied in SQL.
    pub fn blocks_page(&self, range: Range, kind: Option<Kind>, limit: usize, now_ms: i64) -> Result<Vec<Block>> {
        let mut st = self.conn.prepare(&format!(
            "SELECT {BLOCK_COLS} FROM blocks
             WHERE started_ms >= ?1 AND started_ms < ?2 AND (?3 IS NULL OR kind = ?3)
             ORDER BY started_ms DESC, id DESC LIMIT ?4"
        ))?;
        let limit = limit.min(i64::MAX as usize) as i64;
        let rows =
            st.query_map(params![range.from_ms, range.to_ms, kind.map(Kind::as_str), limit], row_to_block)?;
        let mut out: Vec<Block> = rows.collect::<rusqlite::Result<_>>()?;
        for b in &mut out {
            if let Some(s) = b.settled_at(now_ms) {
                *b = s;
            }
        }
        Ok(out)
    }

    /// Raw `blocks` table rows in `range` (not settled at any `now`); equals the fold of the log.
    pub fn projected_blocks(&self, range: Range) -> Result<Vec<Block>> {
        let mut st = self.conn.prepare(&format!(
            "SELECT {BLOCK_COLS} FROM blocks WHERE started_ms >= ?1 AND started_ms < ?2 ORDER BY started_ms, id"
        ))?;
        let rows = st.query_map(params![range.from_ms, range.to_ms], row_to_block)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Focus statistics for blocks started in `range`; days use the fixed UTC offset `tz_offset_min`.
    /// Only the blocks in `range` are loaded; the streak reads the distinct days of completed
    /// focus blocks from SQL.
    pub fn stats(&self, range: Range, tz_offset_min: i32, now_ms: i64) -> Result<Stats> {
        let in_range = self.blocks(range, now_ms)?;
        let (focus_ms_by_day, focus_ms_total, completed_focus) = stats::range_totals(&in_range, tz_offset_min);
        let off = i64::from(tz_offset_min) * 60_000;
        let mut st = self.conn.prepare(
            "SELECT DISTINCT ((started_ms + ?1) / 86400000)
                    - (CASE WHEN (started_ms + ?1) % 86400000 < 0 THEN 1 ELSE 0 END)
             FROM blocks WHERE kind = 'focus' AND outcome = 'completed'",
        )?;
        let mut days: BTreeSet<i64> =
            st.query_map([off], |r| r.get::<_, i64>(0))?.collect::<rusqlite::Result<_>>()?;
        // The live block may have run out at `now_ms` without an event settling it.
        if let Some(id) = self.state.current_id() {
            if let Some(b) = self.block(id, now_ms)? {
                if b.kind == Kind::Focus && b.outcome == Some(Outcome::Completed) {
                    days.insert(stats::day_number(b.started_ms, tz_offset_min));
                }
            }
        }
        let streak_days = stats::streak(&days, stats::day_number(now_ms, tz_offset_min));
        Ok(Stats { focus_ms_by_day, focus_ms_total, completed_focus, streak_days })
    }
}
