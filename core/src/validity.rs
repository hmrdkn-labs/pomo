//! Event validity bounds (spec/events.md, "Validity bounds"). One rule set for events ingested
//! from peers and events issued by local commands.

use serde_json::Value;

use crate::types::Event;

/// Largest accepted `hlc_ms`: 2100-01-01T00:00:00Z.
pub const MAX_HLC_MS: i64 = 4_102_444_800_000;
/// Largest accepted `hlc_counter`.
pub const MAX_HLC_COUNTER: u32 = 1_000_000;
/// Largest accepted `seq` (2^53, the largest integer every JSON implementation reads exactly).
pub const MAX_SEQ: u64 = 1 << 53;
/// Longest accepted `device_id`, `command_key` and `source`, in bytes.
pub const MAX_ID_BYTES: usize = 128;
/// Largest accepted payload, as compact JSON, in bytes.
pub const MAX_PAYLOAD_BYTES: usize = 16 * 1024;
/// Bounds of `timer.started.planned_ms` and `timer.extended.add_ms` (24 h).
pub const MIN_DURATION_MS: i64 = 1;
pub const MAX_DURATION_MS: i64 = 86_400_000;
/// A block's total `planned_ms` never exceeds this (48 h); a longer extend is a reducer no-op.
pub const MAX_BLOCK_PLANNED_MS: i64 = 172_800_000;
/// Ingest from a peer skips events whose `hlc_ms` is more than this ahead of the receiver's clock.
pub const MAX_FUTURE_SKEW_MS: i64 = 86_400_000;

/// Whether `s` is a lowercase hyphenated UUID (`8-4-4-4-12` hex digits, any version).
pub fn is_uuid(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 36
        && b.iter().enumerate().all(|(i, c)| match i {
            8 | 13 | 18 | 23 => *c == b'-',
            _ => c.is_ascii_digit() || (b'a'..=b'f').contains(c),
        })
}

/// Whether `ms` is a valid `planned_ms` / `add_ms`.
pub fn duration_in_bounds(ms: i64) -> bool {
    (MIN_DURATION_MS..=MAX_DURATION_MS).contains(&ms)
}

struct ByteCount(usize);

impl std::io::Write for ByteCount {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0 += buf.len();
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn json_len(v: &Value) -> usize {
    let mut c = ByteCount(0);
    // Serializing a `Value` to a counter cannot fail.
    let _ = serde_json::to_writer(&mut c, v);
    c.0
}

/// Checks the validity bounds. `Err` carries the reason. A payload that is merely malformed
/// (missing or non-integer `planned_ms`, unknown type) is valid: it is stored and ignored by
/// the reducer. An integer duration outside the bounds is invalid.
pub fn validate_event(e: &Event) -> Result<(), String> {
    if !is_uuid(&e.id) {
        return Err("id is not a lowercase hyphenated UUID".into());
    }
    if e.device_id.is_empty() {
        return Err("empty device_id".into());
    }
    if e.device_id.len() > MAX_ID_BYTES {
        return Err(format!("device_id longer than {MAX_ID_BYTES} bytes"));
    }
    if e.seq < 1 || e.seq > MAX_SEQ {
        return Err("seq out of range".into());
    }
    if !(0..=MAX_HLC_MS).contains(&e.hlc_ms) {
        return Err("hlc_ms out of range".into());
    }
    if e.hlc_counter > MAX_HLC_COUNTER {
        return Err("hlc_counter out of range".into());
    }
    if let Some(k) = &e.command_key {
        if k.is_empty() {
            return Err("empty command_key".into());
        }
        if k.len() > MAX_ID_BYTES {
            return Err(format!("command_key longer than {MAX_ID_BYTES} bytes"));
        }
    }
    if e.source.to_string().len() > MAX_ID_BYTES {
        return Err(format!("source longer than {MAX_ID_BYTES} bytes"));
    }
    let Some(obj) = e.payload.as_object() else {
        return Err("payload is not an object".into());
    };
    if json_len(&e.payload) > MAX_PAYLOAD_BYTES {
        return Err(format!("payload larger than {MAX_PAYLOAD_BYTES} bytes"));
    }
    let field = match e.ty.as_str() {
        "timer.started" => Some("planned_ms"),
        "timer.extended" => Some("add_ms"),
        _ => None,
    };
    if let Some(f) = field {
        if let Some(ms) = obj.get(f).and_then(Value::as_i64) {
            if !duration_in_bounds(ms) {
                return Err(format!("{f} must be in {MIN_DURATION_MS}..={MAX_DURATION_MS}"));
            }
        }
    }
    Ok(())
}
