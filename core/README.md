# pomo-core

Rust Core implementing `spec/events.md` and `spec/schema.sql`. Times are `i64` ms since epoch.
Import everything from the crate root (`use pomo_core::*`).

## Store (`Store`, SQLite via rusqlite/bundled)

```rust
Store::open(path: impl AsRef<Path>, device_id: &str) -> Result<Store>
Store::open_in_memory(device_id: &str) -> Result<Store>
Store::open_with(path, device_id, config: Config) -> Result<Store>
Store::open_in_memory_with(device_id, config: Config) -> Result<Store>

store.device_id() -> &str
store.apply(cmd: Command, source: Source, now_ms: i64) -> Result<Event>        // HLC, seq, command_key idempotency, validity
store.ingest(events: &[Event]) -> Result<IngestReport>                          // idempotent by id; seq/command_key conflicts rejected into report.conflicts
store.ingest_atomic(events: &[Event]) -> Result<IngestReport>                   // same, but any conflict -> Err(Error::Conflict), nothing stored
store.version_vector() -> Result<VersionVector>                                 // BTreeMap<device_id, max seq>
store.events_after(vv: &VersionVector) -> Result<Vec<Event>>                    // ordered by (device_id, seq)
store.events() -> Result<Vec<Event>>                                            // total order
store.timer(now_ms: i64) -> TimerView
store.blocks(range: Range, now_ms: i64) -> Result<Vec<Block>>                   // from `blocks` table, settled at now_ms
store.projected_blocks(range: Range) -> Result<Vec<Block>>                      // raw table rows == fold(events)
store.stats(range: Range, tz_offset_min: i32, now_ms: i64) -> Result<Stats>
store.rebuild_projections() -> Result<()>

// Devices (table `devices`; `paired`/`revoked` are local trust state, never synced)
store.device(id) -> Result<Option<Device>>
store.devices() -> Result<Vec<Device>>                                          // own Device included, ordered by id
store.upsert_device(id, name) -> Result<()>                                     // records the Device, sets its name, trust untouched
store.set_device_paired(id, bool) -> Result<()>                                 // records the Device when new; independent of `revoked`
store.set_device_revoked(id, bool) -> Result<()>

// Peer addresses (table `peers`, migration 0002; local only, opaque string, e.g. an iroh endpoint ticket)
store.peer_address(id) -> Result<Option<String>>
store.set_peer_address(id, address, now_ms) -> Result<()>
```

`apply` errors and writes nothing when the command is not valid: `InvalidArgument` (non-positive `planned_ms`/`add_ms`), `InvalidState` (nothing to pause, no live block, ...), `NotFound` (unknown block id). A used `(device_id, command_key)` returns the original event.
A store is bound to the `device_id` it was created with (`Error::DeviceMismatch` otherwise).
Ingest does not require gap-free `seq`; `events_after` uses max seq per device, so peers must ship each device's events in `seq` order without holes (the sync layer's job).

## Pure reducer

```rust
sort_events(events: &mut [Event])                    // total order (hlc_ms, hlc_counter, device_id, seq)
fold(events_sorted: &[Event], config: Config) -> State
state.at(now_ms: i64) -> (TimerView, Vec<Block>)     // settles at now; blocks ordered (started_ms, id)
state.apply(&Event); state.blocks_sorted() -> Vec<Block>
Event::parse_payload() -> Option<Payload>
```

## Types

```rust
Event { id, device_id, seq: u64, hlc_ms: i64, hlc_counter: u32, ty /* JSON "type" */, payload: Value, source: Source, command_key: Option<String> }
Source::User | Source::Agent(String)                 // JSON "user" | "agent:<name>"
Kind { Focus, ShortBreak, LongBreak }  Phase { Running, Paused, Ended }  Outcome { Completed, Skipped, Abandoned }
Config { long_break_every: u32 /* default 4 */ }
Block { id, kind, label, project, source, device_id, started_ms, planned_ms, elapsed_ms, phase, phase_since_ms, outcome, ended_ms }
TimerView { status: Idle|Running|Paused, block_id?, kind?, remaining_ms?, next_kind }
Command { body: CommandBody, command_key: Option<String> }   // JSON: {"type":"start","kind":..,"planned_ms":..,"command_key":..}
CommandBody::{ Start{kind,planned_ms,label,project}, Pause, Resume, Extend{add_ms}, Skip, Stop, Reset, Label{block_id,label,project} }
Range { from_ms, to_ms }  // half-open on started_ms; Range::ALL
Stats { focus_ms_by_day: BTreeMap<"YYYY-MM-DD", i64>, focus_ms_total, completed_focus, streak_days }
IngestReport { inserted, duplicates, conflicts: Vec<Rejected>, invalid: Vec<Rejected> }
Device { device_id, name: Option<String>, paired, revoked }
Error::{ Db, Json, InvalidArgument, InvalidState, NotFound, Conflict, DeviceMismatch }
```

Stats count each block's stored `elapsed_ms` (a live block counts the time elapsed up to its last pause/start, not up to `now`). Days use a fixed UTC offset; IANA names are not supported.
