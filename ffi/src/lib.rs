//! Pomo FFI: the Core and the Sync node in one object, exported through UniFFI to the Apple
//! Shells. Shapes mirror `spec/api.md` (the Daemon's JSON) as native records; times are integer
//! milliseconds since the Unix epoch.
//!
//! One `PomoCore` owns a tokio runtime, the store and a `pomo-sync` node. Commands, queries and
//! device management are plain blocking calls (SQLite, no network). `join`, `sync_now` and
//! `sync_idle` touch the network and are `async` on the Swift side; their work runs on the
//! object's own runtime.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

use pomo_core as core;
use pomo_core::{Command, CommandBody, Range, Source, Store};
use pomo_sync::{Network, SyncNode, SyncOptions};
use tokio::sync::{broadcast, mpsc};

uniffi::setup_scaffolding!();

const DAY_MS: i64 = 86_400_000;

// ---------- enums ----------

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CoreKind {
    Focus,
    ShortBreak,
    LongBreak,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CorePhase {
    Running,
    Paused,
    Ended,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CoreOutcome {
    Completed,
    Skipped,
    Abandoned,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CoreTimerStatus {
    Idle,
    Running,
    Paused,
}

/// Which network the sync endpoint uses: `N0` is the real relays, `Local` is loopback only
/// (tests, same-machine use).
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CoreNetwork {
    N0,
    Local,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CoreGroupBy {
    Day,
    Label,
    Project,
}

impl From<core::Kind> for CoreKind {
    fn from(k: core::Kind) -> Self {
        match k {
            core::Kind::Focus => CoreKind::Focus,
            core::Kind::ShortBreak => CoreKind::ShortBreak,
            core::Kind::LongBreak => CoreKind::LongBreak,
        }
    }
}

impl From<CoreKind> for core::Kind {
    fn from(k: CoreKind) -> Self {
        match k {
            CoreKind::Focus => core::Kind::Focus,
            CoreKind::ShortBreak => core::Kind::ShortBreak,
            CoreKind::LongBreak => core::Kind::LongBreak,
        }
    }
}

impl From<core::Phase> for CorePhase {
    fn from(p: core::Phase) -> Self {
        match p {
            core::Phase::Running => CorePhase::Running,
            core::Phase::Paused => CorePhase::Paused,
            core::Phase::Ended => CorePhase::Ended,
        }
    }
}

impl From<core::Outcome> for CoreOutcome {
    fn from(o: core::Outcome) -> Self {
        match o {
            core::Outcome::Completed => CoreOutcome::Completed,
            core::Outcome::Skipped => CoreOutcome::Skipped,
            core::Outcome::Abandoned => CoreOutcome::Abandoned,
        }
    }
}

impl From<core::TimerStatus> for CoreTimerStatus {
    fn from(s: core::TimerStatus) -> Self {
        match s {
            core::TimerStatus::Idle => CoreTimerStatus::Idle,
            core::TimerStatus::Running => CoreTimerStatus::Running,
            core::TimerStatus::Paused => CoreTimerStatus::Paused,
        }
    }
}

// ---------- records ----------

/// `Block` of spec/api.md. For a live block `elapsed_ms` is the value at the query's `now`.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreBlock {
    pub id: String,
    pub kind: CoreKind,
    pub label: Option<String>,
    pub project: Option<String>,
    /// `user` or `agent:<name>`.
    pub source: String,
    pub device_id: String,
    pub started_ms: i64,
    pub planned_ms: i64,
    pub elapsed_ms: i64,
    pub phase: CorePhase,
    pub outcome: Option<CoreOutcome>,
    pub ended_ms: Option<i64>,
}

/// `Timer` of spec/api.md.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreTimer {
    pub status: CoreTimerStatus,
    pub block: Option<CoreBlock>,
    pub remaining_ms: Option<i64>,
    pub next_kind: CoreKind,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreToday {
    pub focus_ms: i64,
    pub completed_focus: u64,
}

/// `GET /v1/status`.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreStatus {
    pub now_ms: i64,
    pub timer: CoreTimer,
    pub today: CoreToday,
}

/// The event envelope of spec/events.md. `payload_json` is the payload object as JSON text.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreEvent {
    pub id: String,
    pub device_id: String,
    pub seq: u64,
    pub hlc_ms: i64,
    pub hlc_counter: u32,
    pub event_type: String,
    pub payload_json: String,
    pub source: String,
    pub command_key: Option<String>,
}

/// `POST /v1/commands` response.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreCommandResult {
    pub event: CoreEvent,
    pub timer: CoreTimer,
    pub replayed: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreStatGroup {
    pub key: String,
    pub focus_ms: i64,
    pub completed_focus: u64,
}

/// `GET /v1/stats`.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreStats {
    pub from_ms: i64,
    pub to_ms: i64,
    pub tz_offset_min: i32,
    pub focus_ms: i64,
    pub completed_focus: u64,
    pub streak_days: u64,
    pub groups: Vec<CoreStatGroup>,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreDevice {
    pub device_id: String,
    pub name: Option<String>,
    pub paired: bool,
    pub revoked: bool,
}

/// `GET /v1/devices`: this Device plus the others it knows.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreDevices {
    pub device_id: String,
    pub name: String,
    pub devices: Vec<CoreDevice>,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CorePairingTicket {
    /// `pomo-pair:...`
    pub ticket: String,
    pub expires_ms: i64,
}

/// One entry of `POST /v1/sync`: `error` is set when this peer failed.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreSyncResult {
    pub device_id: String,
    pub sent: u64,
    pub received: u64,
    pub error: Option<String>,
}

// ---------- commands ----------

/// A Command (spec/events.md). For `Label`, `project` of `None` leaves the project untouched
/// and an empty string clears it; `label` of `None` clears the label.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CoreCommand {
    Start { kind: CoreKind, planned_ms: i64, label: Option<String>, project: Option<String> },
    Pause,
    Resume,
    Extend { add_ms: i64 },
    Skip,
    Stop,
    Reset,
    Label { block_id: Option<String>, label: Option<String>, project: Option<String> },
}

impl CoreCommand {
    fn into_body(self) -> CommandBody {
        match self {
            CoreCommand::Start { kind, planned_ms, label, project } => {
                CommandBody::Start { kind: kind.into(), planned_ms, label, project }
            }
            CoreCommand::Pause => CommandBody::Pause,
            CoreCommand::Resume => CommandBody::Resume,
            CoreCommand::Extend { add_ms } => CommandBody::Extend { add_ms },
            CoreCommand::Skip => CommandBody::Skip,
            CoreCommand::Stop => CommandBody::Stop,
            CoreCommand::Reset => CommandBody::Reset,
            CoreCommand::Label { block_id, label, project } => CommandBody::Label {
                block_id,
                label,
                project: project.map(|p| if p.is_empty() { None } else { Some(p) }),
            },
        }
    }
}

// ---------- errors ----------

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    /// A bad argument (non-positive duration, malformed source, ...).
    #[error("{message}")]
    InvalidArgument { message: String },
    /// The command is not valid for the current Timer state.
    #[error("{message}")]
    InvalidState { message: String },
    #[error("{message}")]
    NotFound { message: String },
    #[error("{message}")]
    BadTicket { message: String },
    /// The other Device refused the pairing (bad secret, expired, used).
    #[error("{message}")]
    PairingRejected { message: String },
    /// Network or protocol failure during pairing or sync.
    #[error("{message}")]
    Sync { message: String },
    /// Storage failure or other internal error.
    #[error("{message}")]
    Internal { message: String },
}

impl From<core::Error> for CoreError {
    fn from(e: core::Error) -> Self {
        let message = e.to_string();
        match e {
            core::Error::InvalidArgument(_) => CoreError::InvalidArgument { message },
            core::Error::InvalidState(_) => CoreError::InvalidState { message },
            core::Error::NotFound(_) => CoreError::NotFound { message },
            core::Error::Conflict(_) | core::Error::Db(_) | core::Error::Json(_) | core::Error::DeviceMismatch { .. } => {
                CoreError::Internal { message }
            }
        }
    }
}

impl From<pomo_sync::Error> for CoreError {
    fn from(e: pomo_sync::Error) -> Self {
        let message = e.to_string();
        match e {
            pomo_sync::Error::BadTicket(_) => CoreError::BadTicket { message },
            pomo_sync::Error::Rejected(reason) => CoreError::PairingRejected {
                message: format!("the other Device rejected the pairing: {reason}"),
            },
            pomo_sync::Error::NotPaired(_) => CoreError::InvalidState { message },
            pomo_sync::Error::Store(e) => e.into(),
            _ => CoreError::Sync { message },
        }
    }
}

type Result<T, E = CoreError> = std::result::Result<T, E>;

fn internal(e: impl std::fmt::Display) -> CoreError {
    CoreError::Internal { message: e.to_string() }
}

// ---------- listener ----------

/// Called for every event newly stored on this Device, whether a local Command or a peer's.
/// Called from a runtime thread, never inside a Command call; hop to your own queue before
/// touching UI state.
#[uniffi::export(with_foreign)]
pub trait PomoListener: Send + Sync {
    fn on_event(&self, event: CoreEvent);
}

// ---------- conversions ----------

fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

fn block_view(b: &core::Block, now: i64) -> CoreBlock {
    let elapsed_ms = if b.phase == core::Phase::Running { b.elapsed_ms + (now - b.phase_since_ms).max(0) } else { b.elapsed_ms };
    CoreBlock {
        id: b.id.clone(),
        kind: b.kind.into(),
        label: b.label.clone(),
        project: b.project.clone(),
        source: b.source.to_string(),
        device_id: b.device_id.clone(),
        started_ms: b.started_ms,
        planned_ms: b.planned_ms,
        elapsed_ms,
        phase: b.phase.into(),
        outcome: b.outcome.map(Into::into),
        ended_ms: b.ended_ms,
    }
}

fn timer_view(store: &Store, now: i64) -> Result<CoreTimer> {
    let t = store.timer(now);
    let block = match &t.block_id {
        Some(id) => store.blocks(Range::ALL, now)?.iter().find(|b| &b.id == id).map(|b| block_view(b, now)),
        None => None,
    };
    Ok(CoreTimer { status: t.status.into(), block, remaining_ms: t.remaining_ms, next_kind: t.next_kind.into() })
}

fn event_view(e: &core::Event) -> CoreEvent {
    CoreEvent {
        id: e.id.clone(),
        device_id: e.device_id.clone(),
        seq: e.seq,
        hlc_ms: e.hlc_ms,
        hlc_counter: e.hlc_counter,
        event_type: e.ty.clone(),
        payload_json: e.payload.to_string(),
        source: e.source.to_string(),
        command_key: e.command_key.clone(),
    }
}

fn device_view(d: &core::Device) -> CoreDevice {
    CoreDevice { device_id: d.device_id.clone(), name: d.name.clone(), paired: d.paired, revoked: d.revoked }
}

/// Calendar day `YYYY-MM-DD` of `ms` in a fixed UTC offset (same as the Daemon's `civil_day`).
fn civil_day(ms: i64, tz_min: i32) -> String {
    let days = (ms + i64::from(tz_min) * 60_000).div_euclid(DAY_MS);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}")
}

fn check_tz(tz_offset_min: i32) -> Result<()> {
    if (-1440..=1440).contains(&tz_offset_min) {
        Ok(())
    } else {
        Err(CoreError::InvalidArgument { message: "tz_offset_min out of range".into() })
    }
}

fn parse_source(source: Option<String>) -> Result<Source> {
    let Some(s) = source else { return Ok(Source::User) };
    match s.strip_prefix("agent:") {
        _ if s == "user" => Ok(Source::User),
        Some(n)
            if (1..=32).contains(&n.len())
                && n.bytes().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_' || c == b'-') =>
        {
            Ok(Source::Agent(n.to_string()))
        }
        _ => Err(CoreError::InvalidArgument {
            message: "source must be `user` or `agent:<name>` with name [a-z0-9_-]{1,32}".into(),
        }),
    }
}

fn random_key() -> String {
    use rand::RngCore;
    let mut b = [0u8; 16];
    rand::rngs::OsRng.fill_bytes(&mut b);
    b.iter().map(|x| format!("{x:02x}")).collect()
}

// ---------- the object ----------

type SharedListener = Arc<Mutex<Option<Arc<dyn PomoListener>>>>;

/// The Core and its Sync node.
#[derive(uniffi::Object)]
pub struct PomoCore {
    rt: tokio::runtime::Runtime,
    node: Arc<SyncNode>,
    store: Arc<Mutex<Store>>,
    device_id: String,
    listener: SharedListener,
    events: mpsc::UnboundedSender<Vec<core::Event>>,
}

impl PomoCore {
    fn store(&self) -> MutexGuard<'_, Store> {
        self.store.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn own_name(&self) -> String {
        self.store().device(&self.device_id).ok().flatten().and_then(|d| d.name).unwrap_or_else(|| "Pomo".to_string())
    }

    fn execute(&self, body: CommandBody, source: Source, command_key: Option<String>) -> Result<CoreCommandResult> {
        let key = match command_key {
            Some(k) if k.is_empty() => {
                return Err(CoreError::InvalidArgument { message: "command_key must not be empty".into() })
            }
            Some(k) => k,
            None => random_key(),
        };
        let now = now_ms();
        let (event, replayed, timer) = {
            let mut store = self.store();
            let before = store.version_vector()?;
            let event = store.apply(Command { body, command_key: Some(key) }, source, now)?;
            let replayed = before.get(&event.device_id).is_some_and(|max| event.seq <= *max);
            let timer = timer_view(&store, now)?;
            (event, replayed, timer)
        };
        if !replayed {
            self.node.notify();
            let _ = self.events.send(vec![event.clone()]);
        }
        Ok(CoreCommandResult { event: event_view(&event), timer, replayed })
    }

    /// Syncs `ids` concurrently on the runtime; failures are entries, not errors.
    async fn sync_ids(&self, ids: Vec<String>) -> Vec<CoreSyncResult> {
        let mut set = tokio::task::JoinSet::new();
        for (i, id) in ids.into_iter().enumerate() {
            let node = self.node.clone();
            set.spawn_on(
                async move {
                    let r = node.sync_with(&id).await;
                    (
                        i,
                        match r {
                            Ok(r) => CoreSyncResult {
                                device_id: id,
                                sent: r.sent as u64,
                                received: r.received as u64,
                                error: None,
                            },
                            Err(e) => CoreSyncResult { device_id: id, sent: 0, received: 0, error: Some(e.to_string()) },
                        },
                    )
                },
                self.rt.handle(),
            );
        }
        let mut out = Vec::new();
        while let Some(r) = set.join_next().await {
            if let Ok(r) = r {
                out.push(r);
            }
        }
        out.sort_by_key(|(i, _)| *i);
        out.into_iter().map(|(_, r)| r).collect()
    }

    /// Paired, non-revoked Devices that can be dialed; with `skip_connected` not those with an open session.
    fn peer_ids(&self, skip_connected: bool) -> Result<Vec<String>> {
        let devices = self.store().devices()?;
        Ok(devices
            .into_iter()
            .filter(|d| d.paired && !d.revoked && d.device_id != self.device_id)
            .map(|d| d.device_id)
            .filter(|id| self.node.knows_address(id) && !(skip_connected && self.node.has_session(id)))
            .collect())
    }
}

#[uniffi::export]
impl PomoCore {
    /// Opens (creating when absent) the store `<dir>/pomo.db` and the device key
    /// `<dir>/meta/key`, and starts the Sync node. `device_name` is stored as this Device's name
    /// when non-empty; otherwise the stored name is kept (default "Pomo").
    #[uniffi::constructor]
    pub fn open(dir: String, device_name: String, network: CoreNetwork) -> Result<Arc<PomoCore>> {
        let dir = Path::new(&dir);
        std::fs::create_dir_all(dir).map_err(internal)?;
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("pomo-ffi")
            .enable_all()
            .build()
            .map_err(internal)?;
        let (mut store, key) = pomo_sync::open_store(&dir.join("pomo.db"), &dir.join("meta").join("key"))?;
        let device_id = store.device_id().to_string();
        let stored = store.device(&device_id)?.and_then(|d| d.name);
        let name = if device_name.trim().is_empty() { stored.unwrap_or_else(|| "Pomo".into()) } else { device_name };
        store.upsert_device(&device_id, &name)?;
        let store = Arc::new(Mutex::new(store));
        let network = match network {
            CoreNetwork::N0 => Network::N0,
            CoreNetwork::Local => Network::Local,
        };
        let opts = SyncOptions { network, ..SyncOptions::default() };
        let node = Arc::new(rt.block_on(SyncNode::start(store.clone(), key, opts))?);

        let listener: SharedListener = Arc::new(Mutex::new(None));
        let (events, mut rx) = mpsc::unbounded_channel::<Vec<core::Event>>();
        {
            let listener = listener.clone();
            rt.spawn(async move {
                while let Some(batch) = rx.recv().await {
                    let l = listener.lock().unwrap_or_else(|e| e.into_inner()).clone();
                    if let Some(l) = l {
                        for e in &batch {
                            l.on_event(event_view(e));
                        }
                    }
                }
            });
        }
        {
            let mut sub = node.subscribe();
            let events = events.clone();
            rt.spawn(async move {
                loop {
                    match sub.recv().await {
                        Ok(batch) => {
                            if events.send(batch).is_err() {
                                return;
                            }
                        }
                        Err(broadcast::error::RecvError::Lagged(_)) => {}
                        Err(broadcast::error::RecvError::Closed) => return,
                    }
                }
            });
        }
        Ok(Arc::new(PomoCore { rt, node, store, device_id, listener, events }))
    }

    /// This Device's id (its iroh endpoint id).
    pub fn device_id(&self) -> String {
        self.device_id.clone()
    }

    pub fn device_name(&self) -> String {
        self.own_name()
    }

    /// Replaces the listener; `None` removes it.
    pub fn set_listener(&self, listener: Option<Arc<dyn PomoListener>>) {
        *self.listener.lock().unwrap_or_else(|e| e.into_inner()) = listener;
    }

    // ----- queries -----

    /// The Timer at the current time.
    pub fn timer(&self) -> Result<CoreTimer> {
        timer_view(&self.store(), now_ms())
    }

    /// Timer and today's focus totals, `today` in the fixed UTC offset `tz_offset_min`.
    pub fn status(&self, tz_offset_min: i32) -> Result<CoreStatus> {
        check_tz(tz_offset_min)?;
        let now = now_ms();
        let store = self.store();
        let off = i64::from(tz_offset_min) * 60_000;
        let start = (now + off).div_euclid(DAY_MS) * DAY_MS - off;
        let s = store.stats(Range { from_ms: start, to_ms: start + DAY_MS }, tz_offset_min, now)?;
        Ok(CoreStatus {
            now_ms: now,
            timer: timer_view(&store, now)?,
            today: CoreToday { focus_ms: s.focus_ms_total, completed_focus: u64::from(s.completed_focus) },
        })
    }

    /// Blocks with `started_ms` in `[from_ms, to_ms)`, newest first. `limit` defaults to 100, at most 1000.
    pub fn blocks(
        &self,
        from_ms: Option<i64>,
        to_ms: Option<i64>,
        kind: Option<CoreKind>,
        limit: Option<u32>,
    ) -> Result<Vec<CoreBlock>> {
        let limit = match limit {
            None => 100,
            Some(0) => return Err(CoreError::InvalidArgument { message: "limit must be >= 1".into() }),
            Some(l) => l.min(1000) as usize,
        };
        let range = Range { from_ms: from_ms.unwrap_or(i64::MIN), to_ms: to_ms.unwrap_or(i64::MAX) };
        let kind: Option<core::Kind> = kind.map(Into::into);
        let now = now_ms();
        let mut all = self.store().blocks(range, now)?;
        all.retain(|b| kind.is_none_or(|k| b.kind == k));
        all.sort_by(|a, b| (b.started_ms, &b.id).cmp(&(a.started_ms, &a.id)));
        Ok(all.iter().take(limit).map(|b| block_view(b, now)).collect())
    }

    /// Focus statistics for `[from_ms, to_ms)` (defaults: everything), aggregated like `GET /v1/stats`.
    pub fn stats(
        &self,
        from_ms: Option<i64>,
        to_ms: Option<i64>,
        tz_offset_min: i32,
        group_by: CoreGroupBy,
    ) -> Result<CoreStats> {
        check_tz(tz_offset_min)?;
        let range = Range { from_ms: from_ms.unwrap_or(0), to_ms: to_ms.unwrap_or(i64::MAX) };
        let now = now_ms();
        let store = self.store();
        let s = store.stats(range, tz_offset_min, now)?;
        let mut groups: BTreeMap<String, (i64, u64)> = BTreeMap::new();
        for b in store.blocks(range, now)?.iter().filter(|b| b.kind == core::Kind::Focus) {
            let key = match group_by {
                CoreGroupBy::Day => civil_day(b.started_ms, tz_offset_min),
                CoreGroupBy::Label => b.label.clone().unwrap_or_default(),
                CoreGroupBy::Project => b.project.clone().unwrap_or_default(),
            };
            let g = groups.entry(key).or_default();
            g.0 += b.elapsed_ms;
            g.1 += u64::from(b.outcome == Some(core::Outcome::Completed));
        }
        let mut groups: Vec<(String, (i64, u64))> = groups.into_iter().collect();
        if group_by != CoreGroupBy::Day {
            groups.sort_by(|a, b| b.1 .0.cmp(&a.1 .0).then_with(|| a.0.cmp(&b.0)));
        }
        Ok(CoreStats {
            from_ms: range.from_ms,
            to_ms: range.to_ms,
            tz_offset_min,
            focus_ms: s.focus_ms_total,
            completed_focus: u64::from(s.completed_focus),
            streak_days: u64::from(s.streak_days),
            groups: groups
                .into_iter()
                .map(|(key, (focus_ms, completed_focus))| CoreStatGroup { key, focus_ms, completed_focus })
                .collect(),
        })
    }

    // ----- commands -----

    /// Issues a Command. `source` is `user` (default) or `agent:<name>`. A `command_key` that was
    /// already used returns the original event with `replayed` set and writes nothing.
    pub fn send(
        &self,
        command: CoreCommand,
        source: Option<String>,
        command_key: Option<String>,
    ) -> Result<CoreCommandResult> {
        self.execute(command.into_body(), parse_source(source)?, command_key)
    }

    pub fn start(
        &self,
        kind: CoreKind,
        planned_ms: i64,
        label: Option<String>,
        project: Option<String>,
    ) -> Result<CoreCommandResult> {
        self.execute(CoreCommand::Start { kind, planned_ms, label, project }.into_body(), Source::User, None)
    }

    pub fn pause(&self) -> Result<CoreCommandResult> {
        self.execute(CommandBody::Pause, Source::User, None)
    }

    pub fn resume(&self) -> Result<CoreCommandResult> {
        self.execute(CommandBody::Resume, Source::User, None)
    }

    pub fn extend(&self, add_ms: i64) -> Result<CoreCommandResult> {
        self.execute(CommandBody::Extend { add_ms }, Source::User, None)
    }

    pub fn skip(&self) -> Result<CoreCommandResult> {
        self.execute(CommandBody::Skip, Source::User, None)
    }

    pub fn stop(&self) -> Result<CoreCommandResult> {
        self.execute(CommandBody::Stop, Source::User, None)
    }

    pub fn reset(&self) -> Result<CoreCommandResult> {
        self.execute(CommandBody::Reset, Source::User, None)
    }

    /// Sets the label of `block_id` (default: the current block, else the most recent). `None` clears it.
    pub fn label(&self, block_id: Option<String>, label: Option<String>) -> Result<CoreCommandResult> {
        self.execute(CoreCommand::Label { block_id, label, project: None }.into_body(), Source::User, None)
    }

    // ----- devices and sync -----

    /// This Device and the other Devices it knows.
    pub fn devices(&self) -> Result<CoreDevices> {
        let list = self.store().devices()?;
        Ok(CoreDevices {
            device_id: self.device_id.clone(),
            name: self.own_name(),
            devices: list.iter().filter(|d| d.device_id != self.device_id).map(device_view).collect(),
        })
    }

    /// Revokes a Device and closes its sessions.
    pub fn revoke(&self, device_id: String) -> Result<CoreDevice> {
        if device_id == self.device_id {
            return Err(CoreError::InvalidArgument { message: "cannot revoke this Device itself".into() });
        }
        if self.store().device(&device_id)?.is_none() {
            return Err(CoreError::NotFound { message: format!("unknown device {device_id}") });
        }
        self.node.revoke(&device_id)?;
        let d = self
            .store()
            .device(&device_id)?
            .ok_or_else(|| CoreError::NotFound { message: format!("unknown device {device_id}") })?;
        Ok(device_view(&d))
    }

    /// Asks peers to keep sessions open and forward new events (call with `true` while the app
    /// is in the foreground, `false` when it goes to the background).
    pub fn set_live(&self, live: bool) {
        self.node.set_live(live);
    }

    /// A one-time, five-minute pairing ticket for another Device to `join`.
    pub async fn offer_pairing(self: Arc<Self>) -> Result<CorePairingTicket> {
        let name = self.own_name();
        let node = self.node.clone();
        let t = self.rt.spawn(async move { node.pairing_ticket(&name).await }).await.map_err(internal)??;
        Ok(CorePairingTicket { ticket: t.ticket, expires_ms: t.expires_ms })
    }

    /// Pairs with the Device that offered `ticket` and runs one sync session.
    pub async fn join(self: Arc<Self>, ticket: String) -> Result<CoreDevice> {
        let name = self.own_name();
        let node = self.node.clone();
        let out = self.rt.spawn(async move { node.pair(&ticket, &name).await }).await.map_err(internal)??;
        let d = self
            .store()
            .device(&out.device_id)?
            .ok_or_else(|| CoreError::NotFound { message: format!("unknown device {}", out.device_id) })?;
        Ok(device_view(&d))
    }

    /// Syncs with every paired, non-revoked Device whose address is known. Per-peer failures are
    /// entries with `error` set.
    pub async fn sync_now(self: Arc<Self>) -> Result<Vec<CoreSyncResult>> {
        let ids = self.peer_ids(false)?;
        Ok(self.sync_ids(ids).await)
    }

    /// Like `sync_now`, but skips Devices that already have an open session (for periodic rounds).
    pub async fn sync_idle(self: Arc<Self>) -> Result<Vec<CoreSyncResult>> {
        let ids = self.peer_ids(true)?;
        Ok(self.sync_ids(ids).await)
    }

    /// Stops the Sync node and closes all sessions. Commands keep working on the store.
    pub fn shutdown(&self) {
        self.rt.block_on(self.node.shutdown());
    }
}

#[cfg(test)]
mod tests;
