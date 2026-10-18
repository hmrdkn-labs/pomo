//! SQLite store: canonical event log plus the `blocks` projection.

use std::path::Path;

use rusqlite::{params, Connection, OptionalExtension, Row, Transaction};

use crate::reducer::{fold, State};
use crate::stats;
use crate::types::*;

const MIGRATION_0001: &str = include_str!("../../spec/migrations/0001_init.sql");
const MIGRATION_0002: &str = include_str!("../../spec/migrations/0002_peers.sql");

/// Owned form of [`EventKey`].
type OwnedKey = (i64, u32, String, u64);

fn owned_key(e: &Event) -> OwnedKey {
    (e.hlc_ms, e.hlc_counter, e.device_id.clone(), e.seq)
}

/// One Device's store. Holds the cached fold of the log; keeps `blocks` equal to it.
pub struct Store {
    conn: Connection,
    device_id: String,
    config: Config,
    state: State,
    /// Greatest event position stored.
    last_key: Option<OwnedKey>,
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

fn check_event(e: &Event) -> Option<&'static str> {
    if e.id.is_empty() {
        Some("empty id")
    } else if e.device_id.is_empty() {
        Some("empty device_id")
    } else if e.seq < 1 || e.seq > i64::MAX as u64 {
        Some("seq out of range")
    } else if !e.payload.is_object() {
        Some("payload is not an object")
    } else if e.command_key.as_deref() == Some("") {
        Some("empty command_key")
    } else {
        None
    }
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

    fn init(conn: Connection, device_id: &str, config: Config) -> Result<Store> {
        if device_id.is_empty() {
            return Err(Error::InvalidArgument("empty device_id".into()));
        }
        conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")?;
        let has_meta: bool = conn.query_row(
            "SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE type='table' AND name='meta')",
            [],
            |r| r.get(0),
        )?;
        if !has_meta {
            conn.execute_batch(&format!("BEGIN;\n{MIGRATION_0001}\nCOMMIT;"))?;
            conn.execute(
                "INSERT INTO meta (key, value) VALUES ('schema_version', '1'), ('device_id', ?1)",
                [device_id],
            )?;
        } else {
            let stored: String =
                conn.query_row("SELECT value FROM meta WHERE key='device_id'", [], |r| r.get(0))?;
            if stored != device_id {
                return Err(Error::DeviceMismatch { stored, requested: device_id.to_string() });
            }
        }
        let version: i64 = conn
            .query_row("SELECT value FROM meta WHERE key='schema_version'", [], |r| r.get::<_, String>(0))?
            .parse()
            .unwrap_or(0);
        if version < 2 {
            conn.execute_batch(&format!("BEGIN;\n{MIGRATION_0002}\nCOMMIT;"))?;
        }
        conn.execute("INSERT OR IGNORE INTO devices (device_id) VALUES (?1)", [device_id])?;
        let mut s = Store {
            conn,
            device_id: device_id.to_string(),
            config,
            state: State::new(config),
            last_key: None,
        };
        s.rebuild_projections()?;
        Ok(s)
    }

    /// This store's device id.
    pub fn device_id(&self) -> &str {
        &self.device_id
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
    /// the call is stored. Updates the projection.
    pub fn ingest(&mut self, events: &[Event]) -> Result<IngestReport> {
        self.ingest_with(events, false)
    }

    /// Like [`Store::ingest`], but all-or-nothing on conflicts: when any event collides with a
    /// stored one under a different id (or with another event of the same call), returns
    /// [`Error::Conflict`] and stores nothing. Structurally invalid events are still skipped
    /// and listed in the report.
    pub fn ingest_atomic(&mut self, events: &[Event]) -> Result<IngestReport> {
        self.ingest_with(events, true)
    }

    fn ingest_with(&mut self, events: &[Event], atomic: bool) -> Result<IngestReport> {
        match self.ingest_inner(events, atomic) {
            Ok(r) => Ok(r),
            Err(e) => {
                // A conflict returns before the cached state changes; anything else may
                // leave it ahead of the rolled-back transaction.
                if !matches!(e, Error::Conflict(_)) {
                    let _ = self.rebuild_projections();
                }
                Err(e)
            }
        }
    }

    fn ingest_inner(&mut self, events: &[Event], atomic: bool) -> Result<IngestReport> {
        let tx = self.conn.transaction()?;
        let mut report = IngestReport::default();
        let mut fresh: Vec<&Event> = Vec::new();
        for e in events {
            if let Some(why) = check_event(e) {
                report.invalid.push(Rejected { id: e.id.clone(), reason: why.into() });
                continue;
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
    /// (HLC rule, per-device `seq`). A used `command_key` returns the original event and writes nothing.
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
            Some(l) if now_ms <= l.0 => (l.0, l.1 + 1),
            _ => (now_ms, 0),
        };
        let (timer, blocks) = self.state.at(hlc_ms);
        let live = timer.block_id.clone();
        let payload = match cmd.body {
            CommandBody::Start { kind, planned_ms, label, project } => {
                if planned_ms <= 0 {
                    return Err(Error::InvalidArgument("planned_ms must be > 0".into()));
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
                if add_ms <= 0 {
                    return Err(Error::InvalidArgument("add_ms must be > 0".into()));
                }
                match live {
                    Some(block_id) => Payload::Extended { block_id, add_ms },
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
        let report = self.ingest(std::slice::from_ref(&ev))?;
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

    /// Events the holder of `vv` lacks, ordered by `(device_id, seq)`.
    pub fn events_after(&self, vv: &VersionVector) -> Result<Vec<Event>> {
        let mut out = Vec::new();
        let mut st = self.conn.prepare(&format!(
            "SELECT {EVENT_COLS} FROM events WHERE device_id = ?1 AND seq > ?2 ORDER BY seq"
        ))?;
        for (dev, max) in self.version_vector()? {
            let have = vv.get(&dev).copied().unwrap_or(0);
            if max > have {
                for e in st.query_map(params![dev, have as i64], row_to_event)? {
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

    /// Raw `blocks` table rows in `range` (not settled at any `now`); equals the fold of the log.
    pub fn projected_blocks(&self, range: Range) -> Result<Vec<Block>> {
        let mut st = self.conn.prepare(&format!(
            "SELECT {BLOCK_COLS} FROM blocks WHERE started_ms >= ?1 AND started_ms < ?2 ORDER BY started_ms, id"
        ))?;
        let rows = st.query_map(params![range.from_ms, range.to_ms], row_to_block)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Focus statistics for blocks started in `range`; days use the fixed UTC offset `tz_offset_min`.
    pub fn stats(&self, range: Range, tz_offset_min: i32, now_ms: i64) -> Result<Stats> {
        let all = self.blocks(Range::ALL, now_ms)?;
        Ok(stats::compute(&all, range, tz_offset_min, now_ms))
    }
}
