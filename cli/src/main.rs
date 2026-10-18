use std::io::BufRead;
use std::path::PathBuf;
use std::process::ExitCode;

use chrono::{Local, TimeZone};
use clap::{Parser, Subcommand};
use pomo_cli::client::{default_home, Client, Failure};
use pomo_cli::{mcp, ops};
use serde_json::Value;

#[derive(Parser)]
#[command(name = "pomo", about = "Pomo timer CLI (talks to pomod)")]
struct Cli {
    /// Print exactly the API response body.
    #[arg(long, global = true)]
    json: bool,
    /// Data directory (default: $POMO_HOME or ~/.pomo).
    #[arg(long, global = true)]
    home: Option<PathBuf>,
    /// Source of the command, e.g. agent:claude.
    #[arg(long, global = true)]
    source: Option<String>,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Start a block (default: focus, 25 minutes).
    Start {
        #[arg(long, default_value = "focus", value_parser = ["focus", "short", "long"])]
        kind: String,
        #[arg(long)]
        minutes: Option<f64>,
        #[arg(long)]
        label: Option<String>,
        #[arg(long)]
        project: Option<String>,
    },
    Pause,
    Resume,
    /// Add time to the live block.
    Extend {
        #[arg(long)]
        minutes: f64,
    },
    Skip,
    Stop,
    Reset,
    /// Set the label of a block (default: current, else most recent).
    Label {
        text: String,
        #[arg(long)]
        block: Option<String>,
        #[arg(long)]
        project: Option<String>,
    },
    Status,
    Blocks {
        /// 7d, 24h or an ISO-8601 timestamp.
        #[arg(long)]
        since: Option<String>,
        #[arg(long)]
        limit: Option<u32>,
    },
    Stats {
        #[arg(long)]
        since: Option<String>,
        #[arg(long, value_parser = ["day", "label", "project"])]
        by: Option<String>,
    },
    Events {
        /// Stream new events until interrupted.
        #[arg(long)]
        follow: bool,
    },
    /// Run the MCP server on stdio.
    Mcp,
    /// List this Device and the Devices it knows.
    Devices,
    /// Pair with another Device.
    Pair {
        #[command(subcommand)]
        action: PairCmd,
    },
    /// Sync now with paired Devices.
    Sync {
        /// Only this Device (default: every paired Device with a known address).
        #[arg(long)]
        device: Option<String>,
    },
    /// Stop trusting a Device.
    Revoke { device_id: String },
}

#[derive(Subcommand)]
enum PairCmd {
    /// Print a single-use pairing ticket (five minutes) and a QR code for the other Device.
    Offer,
    /// Join the Device that printed `ticket`.
    Join { ticket: String },
}

fn fmt_dur(ms: i64) -> String {
    let s = ms.max(0) / 1000;
    if s >= 3600 {
        format!("{}:{:02}:{:02}", s / 3600, s % 3600 / 60, s % 60)
    } else {
        format!("{:02}:{:02}", s / 60, s % 60)
    }
}

fn fmt_focus(ms: i64) -> String {
    let m = ms / 60_000;
    if m >= 60 {
        format!("{}h{:02}m", m / 60, m % 60)
    } else {
        format!("{m}m")
    }
}

fn block_desc(b: &Value) -> String {
    let mut s = b["kind"].as_str().unwrap_or("?").to_string();
    if let Some(l) = b["label"].as_str().filter(|l| !l.is_empty()) {
        s.push_str(&format!(" \"{l}\""));
    }
    if let Some(p) = b["project"].as_str().filter(|p| !p.is_empty()) {
        s.push_str(&format!(" [{p}]"));
    }
    s
}

fn timer_line(t: &Value) -> String {
    let status = t["status"].as_str().unwrap_or("?");
    match status {
        "idle" => format!("idle (next: {})", t["next_kind"].as_str().unwrap_or("focus")),
        _ => format!(
            "{status} {} {} left",
            block_desc(&t["block"]),
            fmt_dur(t["remaining_ms"].as_i64().unwrap_or(0))
        ),
    }
}

fn local_time(ms: i64) -> String {
    Local.timestamp_millis_opt(ms).single().map(|d| d.format("%m-%d %H:%M").to_string()).unwrap_or_default()
}

fn render(cmd: &Cmd, v: &Value) {
    match cmd {
        Cmd::Status => {
            let t = &v["today"];
            println!(
                "{} | today: {} focus, {} completed",
                timer_line(&v["timer"]),
                fmt_focus(t["focus_ms"].as_i64().unwrap_or(0)),
                t["completed_focus"]
            );
        }
        Cmd::Blocks { .. } => {
            let blocks = v["blocks"].as_array().cloned().unwrap_or_default();
            if blocks.is_empty() {
                println!("no blocks");
            }
            for b in &blocks {
                let state = b["outcome"].as_str().or(b["phase"].as_str()).unwrap_or("?");
                println!(
                    "{}  {:<10} {:<9} {:>8}/{:<8} {}",
                    local_time(b["started_ms"].as_i64().unwrap_or(0)),
                    b["kind"].as_str().unwrap_or("?"),
                    state,
                    fmt_dur(b["elapsed_ms"].as_i64().unwrap_or(0)),
                    fmt_dur(b["planned_ms"].as_i64().unwrap_or(0)),
                    b["label"].as_str().unwrap_or("")
                );
            }
        }
        Cmd::Stats { .. } => {
            println!(
                "focus {} | {} completed | streak {} day(s)",
                fmt_focus(v["focus_ms"].as_i64().unwrap_or(0)),
                v["completed_focus"],
                v["streak_days"]
            );
            for g in v["groups"].as_array().into_iter().flatten() {
                let key = g["key"].as_str().filter(|k| !k.is_empty()).unwrap_or("(none)");
                println!(
                    "  {key:<24} {:>8}  {} completed",
                    fmt_focus(g["focus_ms"].as_i64().unwrap_or(0)),
                    g["completed_focus"]
                );
            }
        }
        Cmd::Events { .. } => {
            for e in v["events"].as_array().into_iter().flatten() {
                println!("{}", event_line(e));
            }
        }
        Cmd::Devices => {
            println!("this device: {}  {}", v["name"].as_str().unwrap_or("?"), v["device_id"].as_str().unwrap_or("?"));
            let devices = v["devices"].as_array().cloned().unwrap_or_default();
            if devices.is_empty() {
                println!("no other devices (pair one with `pomo pair offer`)");
            }
            for d in &devices {
                println!("{}", device_line(d));
            }
        }
        Cmd::Pair { action: PairCmd::Offer } => {
            let ticket = v["ticket"].as_str().unwrap_or("");
            let mins = (v["expires_ms"].as_i64().unwrap_or(0) - ops::now_ms()).max(0) / 60_000;
            println!("Scan this code, or run `pomo pair join <ticket>` on the other device.");
            println!("Single use, expires in about {} min ({}).\n", mins.max(1), local_time(v["expires_ms"].as_i64().unwrap_or(0)));
            match pomo_cli::qr::render(ticket) {
                Ok(qr) => println!("{qr}\n"),
                Err(e) => eprintln!("pomo: {e}"),
            }
            println!("{ticket}");
        }
        Cmd::Pair { action: PairCmd::Join { .. } } => println!("paired: {}", device_line(&v["device"])),
        Cmd::Sync { .. } => {
            let synced = v["synced"].as_array().cloned().unwrap_or_default();
            if synced.is_empty() {
                println!("no paired devices to sync with");
            }
            for s in &synced {
                let id = s["device_id"].as_str().unwrap_or("?");
                match s["error"].as_str() {
                    Some(e) => println!("{id}  failed: {e}"),
                    None => println!("{id}  sent {}, received {}", s["sent"], s["received"]),
                }
            }
        }
        Cmd::Revoke { .. } => println!("revoked: {}", device_line(&v["device"])),
        _ => {
            let verb = v["event"]["type"].as_str().unwrap_or("").rsplit('.').next().unwrap_or("").to_string();
            let replay = if v["replayed"].as_bool() == Some(true) { " (replayed)" } else { "" };
            println!("{verb}{replay}: {}", timer_line(&v["timer"]));
        }
    }
}

fn device_line(d: &Value) -> String {
    let state = if d["revoked"].as_bool() == Some(true) {
        "revoked"
    } else if d["paired"].as_bool() == Some(true) {
        "paired"
    } else {
        "not paired"
    };
    format!("{:<20} {}  {state}", d["name"].as_str().unwrap_or("(unnamed)"), d["device_id"].as_str().unwrap_or("?"))
}

fn event_line(e: &Value) -> String {
    format!(
        "{}  {:<14} {:<16} {}",
        local_time(e["hlc_ms"].as_i64().unwrap_or(0)),
        e["type"].as_str().unwrap_or("?"),
        e["source"].as_str().unwrap_or("?"),
        e["payload"]
    )
}

fn fail(f: &Failure, json: bool) -> ExitCode {
    if json {
        if let Failure::Api { body, .. } = f {
            if !body.is_null() {
                eprintln!("{body}");
            }
        }
    }
    eprintln!("pomo: {}", f.message());
    ExitCode::from(match f {
        Failure::Unreachable(_) => 2,
        Failure::Api { .. } => 1,
    })
}

fn follow(client: &Client, json: bool) -> Result<(), Failure> {
    let reader = client.stream()?;
    let mut name = String::new();
    for line in reader.lines() {
        let Ok(line) = line else { break };
        if let Some(n) = line.strip_prefix("event:") {
            name = n.trim().to_string();
        } else if let Some(d) = line.strip_prefix("data:") {
            let d = d.trim();
            if json {
                println!("{d}");
            } else if let Ok(v) = serde_json::from_str::<Value>(d) {
                if name == "pomo.event" {
                    println!("{}", event_line(&v));
                } else {
                    println!("{name} {v}");
                }
            }
        }
    }
    Ok(())
}

fn main() -> ExitCode {
    let cli = match Cli::try_parse() {
        Ok(c) => c,
        Err(e) => {
            let _ = e.print();
            return ExitCode::from(if e.use_stderr() { 1 } else { 0 });
        }
    };
    let home = cli.home.clone().unwrap_or_else(default_home);

    if matches!(cli.cmd, Cmd::Mcp) {
        let stdin = std::io::stdin();
        return match mcp::serve(&home, stdin.lock(), std::io::stdout().lock()) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("pomo: {e}");
                ExitCode::from(1)
            }
        };
    }

    let usage = |m: String| {
        eprintln!("pomo: {m}");
        ExitCode::from(1)
    };
    enum Req {
        Command(Value),
        Get(&'static str, ops::Query),
        Post(String, Value),
        Follow,
    }
    let req = match &cli.cmd {
        Cmd::Start { kind, minutes, label, project } => {
            ops::start_body(kind, *minutes, label.as_deref(), project.as_deref()).map(Req::Command)
        }
        Cmd::Pause => Ok(Req::Command(serde_json::json!({"type": "pause"}))),
        Cmd::Resume => Ok(Req::Command(serde_json::json!({"type": "resume"}))),
        Cmd::Extend { minutes } => ops::extend_body(*minutes).map(Req::Command),
        Cmd::Skip => Ok(Req::Command(serde_json::json!({"type": "skip"}))),
        Cmd::Stop => Ok(Req::Command(serde_json::json!({"type": "stop"}))),
        Cmd::Reset => Ok(Req::Command(serde_json::json!({"type": "reset"}))),
        Cmd::Label { text, block, project } => {
            Ok(Req::Command(ops::label_body(text, project.as_deref(), block.as_deref())))
        }
        Cmd::Status => Ok(Req::Get("/v1/status", vec![])),
        Cmd::Blocks { since, limit } => ops::blocks_query(since.as_deref(), *limit).map(|q| Req::Get("/v1/blocks", q)),
        Cmd::Stats { since, by } => ops::stats_query(since.as_deref(), by.as_deref()).map(|q| Req::Get("/v1/stats", q)),
        Cmd::Events { follow: true } => Ok(Req::Follow),
        Cmd::Events { follow: false } => Ok(Req::Get("/v1/events", vec![])),
        Cmd::Devices => Ok(Req::Get("/v1/devices", vec![])),
        Cmd::Pair { action: PairCmd::Offer } => Ok(Req::Post("/v1/pair/offer".into(), serde_json::json!({}))),
        Cmd::Pair { action: PairCmd::Join { ticket } } => {
            Ok(Req::Post("/v1/pair/join".into(), serde_json::json!({"ticket": ticket})))
        }
        Cmd::Sync { device } => {
            let body = device.as_ref().map_or_else(|| serde_json::json!({}), |d| serde_json::json!({"device_id": d}));
            Ok(Req::Post("/v1/sync".into(), body))
        }
        Cmd::Revoke { device_id } => Ok(Req::Post(format!("/v1/devices/{device_id}/revoke"), serde_json::json!({}))),
        Cmd::Mcp => unreachable!(),
    };
    let req = match req {
        Ok(r) => r,
        Err(m) => return usage(m),
    };

    let client = match Client::from_home(&home, cli.source.clone()) {
        Ok(c) => c,
        Err(f) => return fail(&f, cli.json),
    };
    let res = match req {
        Req::Command(body) => client.post_command(&body),
        Req::Get(path, q) => client.get(path, &q),
        Req::Post(path, body) => client.post(&path, &body),
        Req::Follow => {
            return match follow(&client, cli.json) {
                Ok(()) => ExitCode::SUCCESS,
                Err(f) => fail(&f, cli.json),
            }
        }
    };
    match res {
        Ok(v) => {
            if cli.json {
                println!("{v}");
            } else {
                render(&cli.cmd, &v);
            }
            ExitCode::SUCCESS
        }
        Err(f) => fail(&f, cli.json),
    }
}
