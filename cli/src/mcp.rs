//! MCP stdio server (JSON-RPC 2.0, newline-delimited) over the Daemon API.

use std::io::{BufRead, Write};
use std::path::Path;

use serde_json::{json, Value};

use crate::client::{Client, Failure};
use crate::ops;

const DEFAULT_PROTOCOL: &str = "2025-06-18";

fn schema(props: Value, required: &[&str]) -> Value {
    json!({"type": "object", "properties": props, "required": required, "additionalProperties": false})
}

fn tool(name: &str, description: &str, input: Value) -> Value {
    json!({"name": name, "description": description, "inputSchema": input})
}

pub fn tools() -> Vec<Value> {
    let minutes = |d: &str| json!({"type": "number", "exclusiveMinimum": 0, "description": d});
    let text = |d: &str| json!({"type": "string", "description": d});
    let since = json!({"type": "string", "description": "Start of the window: a relative duration like `7d` or `24h`, or an ISO-8601 timestamp such as 2026-01-31T09:00:00Z. Default: all time."});
    vec![
        tool(
            "start_focus",
            "Start a focus block now. Always allowed: a block that is already running or paused is ended as abandoned first. Default length 25 minutes.",
            schema(
                json!({
                    "minutes": minutes("Planned length in minutes (default 25)."),
                    "label": text("What the work is."),
                    "project": text("Optional project the label belongs to."),
                }),
                &[],
            ),
        ),
        tool(
            "start_break",
            "Start a short or long break now. Always allowed: a live block is ended as abandoned first. Defaults: short 5 minutes, long 15.",
            schema(
                json!({
                    "kind": {"type": "string", "enum": ["short", "long"], "description": "Break kind."},
                    "minutes": minutes("Planned length in minutes."),
                }),
                &["kind"],
            ),
        ),
        tool("pause", "Pause the running block. Needs a running block; fails if the timer is idle or already paused.", schema(json!({}), &[])),
        tool("resume", "Resume the paused block. Needs a paused block; fails otherwise.", schema(json!({}), &[])),
        tool("stop", "Stop the live block early; it is recorded as abandoned. Needs a running or paused block.", schema(json!({}), &[])),
        tool("skip", "Skip the live block; it is recorded as skipped. Needs a running or paused block.", schema(json!({}), &[])),
        tool(
            "extend",
            "Add minutes to the live block. Needs a running or paused block.",
            schema(json!({"minutes": minutes("Minutes to add.")}), &["minutes"]),
        ),
        tool("reset", "Restart the live block from its original planned length, discarding extensions and elapsed time. Needs a running or paused block.", schema(json!({}), &[])),
        tool(
            "label_block",
            "Set the label (and optionally project) of a block. Defaults to the current block, else the most recent one. Works on finished blocks too.",
            schema(
                json!({
                    "label": text("New label."),
                    "project": text("New project."),
                    "block_id": text("Block id; default current or most recent block."),
                }),
                &["label"],
            ),
        ),
        tool(
            "get_status",
            "Get the timer state (idle, running or paused, with the live block and remaining time) and today's focus totals. Needs no state.",
            schema(json!({}), &[]),
        ),
        tool(
            "list_blocks",
            "List recorded blocks, newest first. Read-only.",
            schema(
                json!({
                    "since": since.clone(),
                    "limit": {"type": "integer", "minimum": 1, "maximum": 1000, "description": "Maximum number of blocks (default 100)."},
                }),
                &[],
            ),
        ),
        tool(
            "get_stats",
            "Get focus statistics (total focus time, completed focus blocks, streak) with groups by day, label or project. Read-only.",
            schema(
                json!({
                    "since": since,
                    "group_by": {"type": "string", "enum": ["day", "label", "project"], "description": "Grouping (default day)."},
                }),
                &[],
            ),
        ),
    ]
}

fn sanitize_name(name: &str) -> String {
    let s: String = name
        .to_lowercase()
        .chars()
        .map(|c| if c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-' { c } else { '-' })
        .take(32)
        .collect();
    let s = s.trim_matches('-').to_string();
    if s.is_empty() {
        "mcp".into()
    } else {
        s
    }
}

fn str_arg<'a>(args: &'a Value, key: &str) -> Result<Option<&'a str>, String> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => Ok(Some(s)),
        Some(_) => Err(format!("{key} must be a string")),
    }
}

fn num_arg(args: &Value, key: &str) -> Result<Option<f64>, String> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => v.as_f64().map(Some).ok_or_else(|| format!("{key} must be a number")),
    }
}

enum Call {
    Command(Value),
    Get(&'static str, ops::Query),
}

fn plan(name: &str, args: &Value) -> Result<Call, String> {
    let simple = |t: &str| Ok(Call::Command(json!({"type": t})));
    match name {
        "start_focus" => Ok(Call::Command(ops::start_body(
            "focus",
            num_arg(args, "minutes")?,
            str_arg(args, "label")?,
            str_arg(args, "project")?,
        )?)),
        "start_break" => {
            let kind = str_arg(args, "kind")?.ok_or("kind is required (short or long)")?;
            if kind != "short" && kind != "long" {
                return Err("kind must be short or long".into());
            }
            Ok(Call::Command(ops::start_body(kind, num_arg(args, "minutes")?, None, None)?))
        }
        "pause" => simple("pause"),
        "resume" => simple("resume"),
        "stop" => simple("stop"),
        "skip" => simple("skip"),
        "reset" => simple("reset"),
        "extend" => {
            let m = num_arg(args, "minutes")?.ok_or("minutes is required")?;
            Ok(Call::Command(ops::extend_body(m)?))
        }
        "label_block" => {
            let label = str_arg(args, "label")?.ok_or("label is required")?;
            Ok(Call::Command(ops::label_body(label, str_arg(args, "project")?, str_arg(args, "block_id")?)))
        }
        "get_status" => Ok(Call::Get("/v1/status", vec![])),
        "list_blocks" => {
            let limit = match num_arg(args, "limit")? {
                None => None,
                Some(l) if l >= 1.0 && l.fract() == 0.0 => Some(l as u32),
                Some(_) => return Err("limit must be a positive integer".into()),
            };
            Ok(Call::Get("/v1/blocks", ops::blocks_query(str_arg(args, "since")?, limit)?))
        }
        "get_stats" => {
            let g = str_arg(args, "group_by")?;
            if let Some(g) = g {
                if !["day", "label", "project"].contains(&g) {
                    return Err("group_by must be day, label or project".into());
                }
            }
            Ok(Call::Get("/v1/stats", ops::stats_query(str_arg(args, "since")?, g)?))
        }
        other => Err(format!("unknown tool {other:?}")),
    }
}

struct Server<'a> {
    home: &'a Path,
    source: String,
}

impl Server<'_> {
    fn call_tool(&self, name: &str, args: &Value) -> Value {
        let result = plan(name, args).and_then(|call| {
            let client = Client::from_home(self.home, Some(self.source.clone())).map_err(|f| f.message().to_string())?;
            match call {
                Call::Command(body) => client.post_command(&body),
                Call::Get(path, q) => client.get(path, &q),
            }
            .map_err(|f: Failure| f.message().to_string())
        });
        match result {
            Ok(v) => json!({"content": [{"type": "text", "text": v.to_string()}], "isError": false}),
            Err(m) => json!({"content": [{"type": "text", "text": m}], "isError": true}),
        }
    }

    fn handle(&mut self, req: &Value) -> Option<Value> {
        let id = req.get("id").cloned();
        let method = req.get("method").and_then(Value::as_str).unwrap_or("");
        let params = req.get("params").cloned().unwrap_or(Value::Null);
        let reply = |r: Result<Value, (i64, String)>| {
            let id = id.clone()?;
            Some(match r {
                Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
                Err((code, message)) => json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}),
            })
        };
        match method {
            "initialize" => {
                if let Some(n) = params["clientInfo"]["name"].as_str() {
                    self.source = format!("agent:{}", sanitize_name(n));
                }
                let version = params["protocolVersion"].as_str().unwrap_or(DEFAULT_PROTOCOL);
                reply(Ok(json!({
                    "protocolVersion": version,
                    "capabilities": {"tools": {"listChanged": false}},
                    "serverInfo": {"name": "pomo", "version": env!("CARGO_PKG_VERSION")},
                })))
            }
            "ping" => reply(Ok(json!({}))),
            "tools/list" => reply(Ok(json!({"tools": tools()}))),
            "tools/call" => {
                let Some(name) = params["name"].as_str() else {
                    return reply(Err((-32602, "tools/call needs a tool name".into())));
                };
                let args = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
                reply(Ok(self.call_tool(name, &args)))
            }
            _ if id.is_none() => None,
            _ => reply(Err((-32601, format!("method not found: {method}")))),
        }
    }
}

/// Serves MCP on `input`/`output` until EOF.
pub fn serve(home: &Path, input: impl BufRead, mut output: impl Write) -> std::io::Result<()> {
    let mut server = Server { home, source: "agent:mcp".into() };
    for line in input.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let resp = match serde_json::from_str::<Value>(&line) {
            Ok(req) => server.handle(&req),
            Err(e) => Some(json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": format!("parse error: {e}")}})),
        };
        if let Some(r) = resp {
            writeln!(output, "{r}")?;
            output.flush()?;
        }
    }
    Ok(())
}
