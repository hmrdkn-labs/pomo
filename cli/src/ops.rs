//! Request builders shared by the CLI and the MCP server.

use chrono::{DateTime, Utc};
use serde_json::{json, Value};

pub type Query = Vec<(String, String)>;

/// Parses `7d`, `24h`, `90m` (relative to `now_ms`) or an ISO-8601 / RFC 3339 timestamp into epoch ms.
pub fn parse_since(s: &str, now_ms: i64) -> Result<i64, String> {
    let s = s.trim();
    if let Some((num, unit)) = s.split_at_checked(s.len().saturating_sub(1)) {
        let unit_ms = match unit {
            "d" => Some(86_400_000i64),
            "h" => Some(3_600_000),
            "m" => Some(60_000),
            _ => None,
        };
        if let (Some(u), Ok(n)) = (unit_ms, num.parse::<i64>()) {
            if n < 0 {
                return Err(format!("invalid duration {s:?}"));
            }
            return Ok(now_ms - n.saturating_mul(u));
        }
    }
    DateTime::parse_from_rfc3339(s)
        .map(|d| d.with_timezone(&Utc).timestamp_millis())
        .map_err(|_| format!("invalid time {s:?}: use 7d, 24h, 90m or an ISO-8601 timestamp like 2026-01-31T09:00:00Z"))
}

pub fn now_ms() -> i64 {
    Utc::now().timestamp_millis()
}

fn minutes_to_ms(m: f64) -> Result<i64, String> {
    if !m.is_finite() || m <= 0.0 {
        return Err("minutes must be greater than 0".into());
    }
    Ok((m * 60_000.0).round().max(1.0) as i64)
}

/// `kind` is `focus`, `short`/`short_break` or `long`/`long_break`.
pub fn start_body(
    kind: &str,
    minutes: Option<f64>,
    label: Option<&str>,
    project: Option<&str>,
) -> Result<Value, String> {
    let (kind, default_min) = match kind {
        "focus" => ("focus", 25.0),
        "short" | "short_break" => ("short_break", 5.0),
        "long" | "long_break" => ("long_break", 15.0),
        other => return Err(format!("unknown kind {other:?}: use focus, short or long")),
    };
    let mut b = json!({"type": "start", "kind": kind, "planned_ms": minutes_to_ms(minutes.unwrap_or(default_min))?});
    if let Some(l) = label {
        b["label"] = json!(l);
    }
    if let Some(p) = project {
        b["project"] = json!(p);
    }
    Ok(b)
}

pub fn extend_body(minutes: f64) -> Result<Value, String> {
    Ok(json!({"type": "extend", "add_ms": minutes_to_ms(minutes)?}))
}

pub fn label_body(label: &str, project: Option<&str>, block_id: Option<&str>) -> Value {
    let mut b = json!({"type": "label", "label": label});
    if let Some(p) = project {
        b["project"] = json!(p);
    }
    if let Some(id) = block_id {
        b["block_id"] = json!(id);
    }
    b
}

pub fn blocks_query(since: Option<&str>, limit: Option<u32>) -> Result<Query, String> {
    let mut q = Query::new();
    if let Some(s) = since {
        q.push(("from_ms".into(), parse_since(s, now_ms())?.to_string()));
    }
    if let Some(l) = limit {
        q.push(("limit".into(), l.to_string()));
    }
    Ok(q)
}

pub fn stats_query(since: Option<&str>, group_by: Option<&str>) -> Result<Query, String> {
    let mut q = Query::new();
    if let Some(s) = since {
        q.push(("from_ms".into(), parse_since(s, now_ms())?.to_string()));
    }
    if let Some(g) = group_by {
        q.push(("group_by".into(), g.to_string()));
    }
    Ok(q)
}
