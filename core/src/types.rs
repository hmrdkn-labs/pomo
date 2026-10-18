//! Event envelope, payloads, commands and result types (spec/events.md).

use std::collections::BTreeMap;
use std::fmt;

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{json, Map, Value};

/// Who issued a command: `user` or `agent:<name>`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Source {
    User,
    Agent(String),
}

impl fmt::Display for Source {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Source::User => f.write_str("user"),
            Source::Agent(n) => write!(f, "agent:{n}"),
        }
    }
}

impl Source {
    /// Parses `user` or `agent:<name>` (name non-empty).
    pub fn parse(s: &str) -> Option<Source> {
        if s == "user" {
            return Some(Source::User);
        }
        match s.strip_prefix("agent:") {
            Some(n) if !n.is_empty() => Some(Source::Agent(n.to_string())),
            _ => None,
        }
    }
}

impl Serialize for Source {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.collect_str(self)
    }
}

impl<'de> Deserialize<'de> for Source {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        Source::parse(&s).ok_or_else(|| serde::de::Error::custom(format!("invalid source {s:?}")))
    }
}

/// Kind of a block.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Focus,
    ShortBreak,
    LongBreak,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Focus => "focus",
            Kind::ShortBreak => "short_break",
            Kind::LongBreak => "long_break",
        }
    }
    pub fn parse(s: &str) -> Option<Kind> {
        match s {
            "focus" => Some(Kind::Focus),
            "short_break" => Some(Kind::ShortBreak),
            "long_break" => Some(Kind::LongBreak),
            _ => None,
        }
    }
}

/// Lifecycle phase of a block.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Phase {
    Running,
    Paused,
    Ended,
}

impl Phase {
    pub fn as_str(self) -> &'static str {
        match self {
            Phase::Running => "running",
            Phase::Paused => "paused",
            Phase::Ended => "ended",
        }
    }
    pub fn parse(s: &str) -> Option<Phase> {
        match s {
            "running" => Some(Phase::Running),
            "paused" => Some(Phase::Paused),
            "ended" => Some(Phase::Ended),
            _ => None,
        }
    }
}

/// How a block ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    Completed,
    Skipped,
    Abandoned,
}

impl Outcome {
    pub fn as_str(self) -> &'static str {
        match self {
            Outcome::Completed => "completed",
            Outcome::Skipped => "skipped",
            Outcome::Abandoned => "abandoned",
        }
    }
    pub fn parse(s: &str) -> Option<Outcome> {
        match s {
            "completed" => Some(Outcome::Completed),
            "skipped" => Some(Outcome::Skipped),
            "abandoned" => Some(Outcome::Abandoned),
            _ => None,
        }
    }
}

/// An immutable fact. JSON keys match the envelope in spec/events.md.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Event {
    pub id: String,
    pub device_id: String,
    pub seq: u64,
    pub hlc_ms: i64,
    pub hlc_counter: u32,
    #[serde(rename = "type")]
    pub ty: String,
    /// Raw payload object; unknown keys are preserved. Use [`Event::parse_payload`].
    pub payload: Value,
    pub source: Source,
    #[serde(default)]
    pub command_key: Option<String>,
}

/// Position of an event in the total order: `(hlc_ms, hlc_counter, device_id, seq)`.
pub type EventKey<'a> = (i64, u32, &'a str, u64);

impl Event {
    /// Sort key of the total order.
    pub fn key(&self) -> EventKey<'_> {
        (self.hlc_ms, self.hlc_counter, &self.device_id, self.seq)
    }

    /// Typed payload; `None` for unknown types or malformed payloads (such events are ignored by the reducer).
    pub fn parse_payload(&self) -> Option<Payload> {
        Payload::parse(&self.ty, &self.payload)
    }
}

/// Sorts events into the total order (stable, in place).
pub fn sort_events(events: &mut [Event]) {
    events.sort_by(|a, b| a.key().cmp(&b.key()));
}

/// Typed event payload. `Labeled` fields: `None` = key absent, `Some(None)` = present null (clear).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Payload {
    Started {
        block_id: String,
        kind: Kind,
        planned_ms: i64,
        label: Option<String>,
        project: Option<String>,
    },
    Paused { block_id: String },
    Resumed { block_id: String },
    Extended { block_id: String, add_ms: i64 },
    Skipped { block_id: String },
    Stopped { block_id: String },
    Reset { block_id: String },
    Labeled {
        block_id: String,
        label: Option<Option<String>>,
        project: Option<Option<String>>,
    },
}

fn str_field(m: &Map<String, Value>, k: &str) -> Option<String> {
    m.get(k)?.as_str().map(str::to_string)
}

fn opt_str(m: &Map<String, Value>, k: &str) -> Option<Option<String>> {
    match m.get(k) {
        None => Some(None),
        Some(Value::Null) => Some(None),
        Some(Value::String(s)) => Some(Some(s.clone())),
        Some(_) => None,
    }
}

fn nullable_field(m: &Map<String, Value>, k: &str) -> Option<Option<Option<String>>> {
    match m.get(k) {
        None => Some(None),
        Some(Value::Null) => Some(Some(None)),
        Some(Value::String(s)) => Some(Some(Some(s.clone()))),
        Some(_) => None,
    }
}

impl Payload {
    /// Parses `(type, payload)`; `None` when unknown or invalid (e.g. `planned_ms <= 0`).
    pub fn parse(ty: &str, v: &Value) -> Option<Payload> {
        let m = v.as_object()?;
        let block_id = str_field(m, "block_id")?;
        Some(match ty {
            "timer.started" => {
                let planned_ms = m.get("planned_ms")?.as_i64()?;
                if planned_ms <= 0 {
                    return None;
                }
                Payload::Started {
                    block_id,
                    kind: Kind::parse(m.get("kind")?.as_str()?)?,
                    planned_ms,
                    label: opt_str(m, "label")?,
                    project: opt_str(m, "project")?,
                }
            }
            "timer.paused" => Payload::Paused { block_id },
            "timer.resumed" => Payload::Resumed { block_id },
            "timer.extended" => {
                let add_ms = m.get("add_ms")?.as_i64()?;
                if add_ms <= 0 {
                    return None;
                }
                Payload::Extended { block_id, add_ms }
            }
            "timer.skipped" => Payload::Skipped { block_id },
            "timer.stopped" => Payload::Stopped { block_id },
            "timer.reset" => Payload::Reset { block_id },
            "block.labeled" => Payload::Labeled {
                block_id,
                label: nullable_field(m, "label")?,
                project: nullable_field(m, "project")?,
            },
            _ => return None,
        })
    }

    /// Event type string and JSON payload for this variant.
    pub fn to_parts(&self) -> (&'static str, Value) {
        match self {
            Payload::Started { block_id, kind, planned_ms, label, project } => {
                let mut m = Map::new();
                m.insert("block_id".into(), json!(block_id));
                m.insert("kind".into(), json!(kind.as_str()));
                m.insert("planned_ms".into(), json!(planned_ms));
                if let Some(l) = label {
                    m.insert("label".into(), json!(l));
                }
                if let Some(p) = project {
                    m.insert("project".into(), json!(p));
                }
                ("timer.started", Value::Object(m))
            }
            Payload::Paused { block_id } => ("timer.paused", json!({ "block_id": block_id })),
            Payload::Resumed { block_id } => ("timer.resumed", json!({ "block_id": block_id })),
            Payload::Extended { block_id, add_ms } => {
                ("timer.extended", json!({ "block_id": block_id, "add_ms": add_ms }))
            }
            Payload::Skipped { block_id } => ("timer.skipped", json!({ "block_id": block_id })),
            Payload::Stopped { block_id } => ("timer.stopped", json!({ "block_id": block_id })),
            Payload::Reset { block_id } => ("timer.reset", json!({ "block_id": block_id })),
            Payload::Labeled { block_id, label, project } => {
                let mut m = Map::new();
                m.insert("block_id".into(), json!(block_id));
                if let Some(l) = label {
                    m.insert("label".into(), json!(l));
                }
                if let Some(p) = project {
                    m.insert("project".into(), json!(p));
                }
                ("block.labeled", Value::Object(m))
            }
        }
    }
}

/// Reducer settings (not events).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Config {
    #[serde(default = "default_long_break_every")]
    pub long_break_every: u32,
}

fn default_long_break_every() -> u32 {
    4
}

impl Default for Config {
    fn default() -> Self {
        Config { long_break_every: 4 }
    }
}

/// One timed span. Fields follow spec/events.md.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Block {
    pub id: String,
    pub kind: Kind,
    pub label: Option<String>,
    pub project: Option<String>,
    pub source: Source,
    pub device_id: String,
    pub started_ms: i64,
    pub planned_ms: i64,
    pub elapsed_ms: i64,
    pub phase: Phase,
    pub phase_since_ms: i64,
    pub outcome: Option<Outcome>,
    pub ended_ms: Option<i64>,
}

impl Block {
    /// End time of a running block; `None` otherwise.
    pub fn ends_ms(&self) -> Option<i64> {
        (self.phase == Phase::Running).then(|| self.phase_since_ms + self.planned_ms - self.elapsed_ms)
    }

    /// The block as completed if it is running and its end time is `<= now`.
    pub fn settled_at(&self, now: i64) -> Option<Block> {
        let ends = self.ends_ms()?;
        if ends > now {
            return None;
        }
        let mut b = self.clone();
        b.outcome = Some(Outcome::Completed);
        b.elapsed_ms = b.planned_ms;
        b.ended_ms = Some(ends);
        b.phase = Phase::Ended;
        Some(b)
    }
}

/// Timer status.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TimerStatus {
    Idle,
    Running,
    Paused,
}

/// The live Timer at some `now`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TimerView {
    pub status: TimerStatus,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub block_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub kind: Option<Kind>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub remaining_ms: Option<i64>,
    /// Suggested kind of the next block.
    pub next_kind: Kind,
}

/// Command body.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum CommandBody {
    Start {
        kind: Kind,
        planned_ms: i64,
        #[serde(default)]
        label: Option<String>,
        #[serde(default)]
        project: Option<String>,
    },
    Pause,
    Resume,
    Extend { add_ms: i64 },
    Skip,
    Stop,
    Reset,
    /// `block_id` defaults to the current block, else the most recent. `label: None` clears.
    /// `project`: `None` leaves it untouched, `Some(None)` clears, `Some(Some(p))` sets.
    Label {
        #[serde(default)]
        block_id: Option<String>,
        #[serde(default)]
        label: Option<String>,
        #[serde(default, deserialize_with = "double_option")]
        project: Option<Option<String>>,
    },
}

fn double_option<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Option<String>>, D::Error> {
    Option::<String>::deserialize(d).map(Some)
}

/// A request to change the Timer, with an idempotency key.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Command {
    #[serde(flatten)]
    pub body: CommandBody,
    #[serde(default)]
    pub command_key: Option<String>,
}

/// Half-open interval `[from_ms, to_ms)` over `started_ms`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Range {
    pub from_ms: i64,
    pub to_ms: i64,
}

impl Range {
    pub const ALL: Range = Range { from_ms: i64::MIN, to_ms: i64::MAX };

    pub fn contains(&self, ms: i64) -> bool {
        ms >= self.from_ms && ms < self.to_ms
    }
}

/// Statistics for a [`Range`].
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Stats {
    /// Focus time per day (`YYYY-MM-DD`), every day that has a focus block in range.
    pub focus_ms_by_day: BTreeMap<String, i64>,
    pub focus_ms_total: i64,
    pub completed_focus: u32,
    /// Consecutive days with a completed focus block ending today or yesterday (over all blocks, not just the range).
    pub streak_days: u32,
}

/// Map device_id to the max `seq` held for it.
pub type VersionVector = BTreeMap<String, u64>;

/// A rejected event.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Rejected {
    pub id: String,
    pub reason: String,
}

/// Result of [`crate::Store::ingest`].
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct IngestReport {
    pub inserted: usize,
    /// Events whose `id` was already stored.
    pub duplicates: usize,
    /// `(device_id, seq)` or `(device_id, command_key)` collisions with a different id.
    pub conflicts: Vec<Rejected>,
    /// Structurally invalid events.
    pub invalid: Vec<Rejected>,
}

/// A Device known to this store (`devices` table). `paired` and `revoked` are local trust
/// state and are never synced.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Device {
    pub device_id: String,
    pub name: Option<String>,
    pub paired: bool,
    pub revoked: bool,
}

/// Core error.
#[derive(Debug)]
pub enum Error {
    /// Storage failure.
    Db(rusqlite::Error),
    Json(serde_json::Error),
    /// A bad argument (e.g. a non-positive duration, an empty id).
    InvalidArgument(String),
    /// The command is not valid in the current Timer state.
    InvalidState(String),
    /// The referenced block or Device does not exist.
    NotFound(String),
    /// Events collide with stored ones (`(device_id, seq)` or `(device_id, command_key)` under another id).
    Conflict(String),
    /// Store belongs to a different device.
    DeviceMismatch { stored: String, requested: String },
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Db(e) => write!(f, "db: {e}"),
            Error::Json(e) => write!(f, "json: {e}"),
            Error::InvalidArgument(m) | Error::InvalidState(m) | Error::NotFound(m) => f.write_str(m),
            Error::Conflict(m) => write!(f, "conflict: {m}"),
            Error::DeviceMismatch { stored, requested } => {
                write!(f, "store belongs to device {stored}, not {requested}")
            }
        }
    }
}

impl std::error::Error for Error {}

impl From<rusqlite::Error> for Error {
    fn from(e: rusqlite::Error) -> Self {
        Error::Db(e)
    }
}

impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Error::Json(e)
    }
}

pub type Result<T, E = Error> = std::result::Result<T, E>;
