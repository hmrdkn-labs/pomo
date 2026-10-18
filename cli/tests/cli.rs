use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};

use pomod::{Daemon, Options, SyncMode};
use serde_json::{json, Value};

struct Env {
    rt: tokio::runtime::Runtime,
    daemon: Option<Daemon>,
    tmp: tempfile::TempDir,
}

impl Env {
    fn new() -> Env {
        Env::with(SyncMode::Off, "test")
    }

    fn with(sync: SyncMode, name: &str) -> Env {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        let opts = Options {
            port: 0,
            sync,
            name: Some(name.to_string()),
            sync_interval: None,
            ..Options::new(tmp.path().to_path_buf())
        };
        let daemon = rt.block_on(Daemon::start(opts)).unwrap();
        Env { rt, daemon: Some(daemon), tmp }
    }

    fn device_id(&self) -> String {
        self.daemon.as_ref().unwrap().device_id.clone()
    }

    fn pomo(&self, args: &[&str]) -> (i32, String, String) {
        let out = Command::new(env!("CARGO_BIN_EXE_pomo"))
            .arg("--home")
            .arg(self.tmp.path())
            .args(args)
            .env_remove("POMO_HOME")
            .output()
            .unwrap();
        (out.status.code().unwrap(), String::from_utf8(out.stdout).unwrap(), String::from_utf8(out.stderr).unwrap())
    }

    fn json(&self, args: &[&str]) -> Value {
        let mut a = vec!["--json"];
        a.extend_from_slice(args);
        let (code, out, err) = self.pomo(&a);
        assert_eq!(code, 0, "{args:?}: {err}");
        serde_json::from_str(out.trim()).unwrap_or_else(|e| panic!("{args:?}: not JSON ({e}): {out}"))
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        if let Some(d) = self.daemon.take() {
            let _ = self.rt.block_on(d.shutdown());
        }
    }
}

#[test]
fn json_output_is_the_api_body() {
    let e = Env::new();
    let r = e.json(&["start", "--minutes", "1", "--label", "x", "--project", "p"]);
    assert_eq!(r["event"]["type"], "timer.started");
    assert_eq!(r["event"]["payload"]["planned_ms"], 60000);
    assert_eq!(r["event"]["source"], "user");
    assert_eq!(r["timer"]["block"]["label"], "x");

    let s = e.json(&["status"]);
    assert_eq!(s["timer"]["status"], "running");
    assert!(s["now_ms"].is_i64());
    assert_eq!(s["timer"]["block"]["project"], "p");

    assert_eq!(e.json(&["pause"])["timer"]["status"], "paused");
    assert_eq!(e.json(&["resume"])["timer"]["status"], "running");
    assert_eq!(e.json(&["extend", "--minutes", "2"])["timer"]["block"]["planned_ms"], 180000);
    assert_eq!(e.json(&["label", "renamed"])["timer"]["block"]["label"], "renamed");

    let st = e.json(&["stats", "--by", "label"]);
    assert!(st["groups"].is_array());
    let b = e.json(&["blocks", "--since", "7d", "--limit", "5"]);
    assert_eq!(b["blocks"].as_array().unwrap().len(), 1);

    let r = e.json(&["stop"]);
    assert_eq!(r["event"]["type"], "timer.stopped");
    assert_eq!(r["timer"]["status"], "idle");
    let ev = e.json(&["events"]);
    assert_eq!(ev["events"].as_array().unwrap().len(), 6);
}

#[test]
fn kinds_defaults_and_source() {
    let e = Env::new();
    assert_eq!(e.json(&["start"])["event"]["payload"]["planned_ms"], 25 * 60000);
    let r = e.json(&["start", "--kind", "short"]);
    assert_eq!(r["event"]["payload"]["kind"], "short_break");
    assert_eq!(r["event"]["payload"]["planned_ms"], 5 * 60000);
    let r = e.json(&["start", "--kind", "long"]);
    assert_eq!(r["event"]["payload"]["planned_ms"], 15 * 60000);
    let r = e.json(&["--source", "agent:me", "start"]);
    assert_eq!(r["event"]["source"], "agent:me");
}

#[test]
fn human_output_and_exit_codes() {
    let e = Env::new();
    let (c, out, _) = e.pomo(&["status"]);
    assert_eq!(c, 0);
    assert!(out.starts_with("idle (next: focus)"), "{out}");
    let (c, out, _) = e.pomo(&["start", "--minutes", "1", "--label", "x"]);
    assert_eq!(c, 0);
    assert!(out.contains("started: running focus \"x\" 0"), "{out}");
    let (c, out, err) = e.pomo(&["resume"]);
    assert_eq!(c, 1, "{out}");
    assert!(err.contains("pomo:"), "{err}");
    assert_eq!(e.pomo(&["extend", "--minutes", "0"]).0, 1);
    assert_eq!(e.pomo(&["start", "--kind", "bogus"]).0, 1);
    assert_eq!(e.pomo(&["blocks", "--since", "yesterday"]).0, 1);
    let (c, out, _) = e.pomo(&["stats", "--by", "label"]);
    assert_eq!(c, 0);
    assert!(out.starts_with("focus "), "{out}");
}

#[test]
fn unreachable_daemon_exits_2_with_hint() {
    let tmp = tempfile::tempdir().unwrap();
    let run = |args: &[&str]| Command::new(env!("CARGO_BIN_EXE_pomo")).arg("--home").arg(tmp.path()).args(args).output().unwrap();
    let out = run(&["status"]);
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("Start it with: pomod"));

    // Stale daemon.json pointing at a closed port.
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    std::fs::write(tmp.path().join("daemon.json"), json!({"port": port, "pid": 1}).to_string()).unwrap();
    std::fs::write(tmp.path().join("token"), "t").unwrap();
    let out = run(&["--json", "status"]);
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("Start it with: pomod"));
}

#[test]
fn events_follow_streams_new_events() {
    let e = Env::new();
    let mut child = Command::new(env!("CARGO_BIN_EXE_pomo"))
        .args(["--json", "events", "--follow", "--home"])
        .arg(e.tmp.path())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    // Wait for the stream subscription: issue commands until the first line arrives.
    let stdout = child.stdout.take().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for l in BufReader::new(stdout).lines() {
            if tx.send(l.unwrap()).is_err() {
                return;
            }
        }
    });
    std::thread::sleep(std::time::Duration::from_millis(500));
    e.json(&["start", "--minutes", "1"]);
    let line = rx.recv_timeout(std::time::Duration::from_secs(5));
    child.kill().unwrap();
    child.wait().unwrap();
    let v: Value = serde_json::from_str(&line.unwrap()).unwrap();
    assert_eq!(v["type"], "timer.started");
}

struct Mcp {
    child: std::process::Child,
    out: BufReader<std::process::ChildStdout>,
}

impl Mcp {
    fn spawn(home: &std::path::Path) -> Mcp {
        let mut child = Command::new(env!("CARGO_BIN_EXE_pomo"))
            .args(["mcp", "--home"])
            .arg(home)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let out = BufReader::new(child.stdout.take().unwrap());
        Mcp { child, out }
    }
    fn send(&mut self, v: Value) {
        writeln!(self.child.stdin.as_mut().unwrap(), "{v}").unwrap();
    }
    fn recv(&mut self) -> Value {
        let mut l = String::new();
        self.out.read_line(&mut l).unwrap();
        serde_json::from_str(&l).unwrap()
    }
    fn rpc(&mut self, id: i64, method: &str, params: Value) -> Value {
        self.send(json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}));
        let r = self.recv();
        assert_eq!(r["id"], id);
        r
    }
    fn tool(&mut self, name: &str, args: Value) -> Value {
        self.rpc(99, "tools/call", json!({"name": name, "arguments": args}))["result"].clone()
    }
}

impl Drop for Mcp {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
fn mcp_stdio_session() {
    let e = Env::new();
    let mut m = Mcp::spawn(e.tmp.path());

    let r = m.rpc(1, "initialize", json!({"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Claude Code","version":"1"}}));
    assert_eq!(r["result"]["protocolVersion"], "2025-06-18");
    assert_eq!(r["result"]["serverInfo"]["name"], "pomo");
    assert!(r["result"]["capabilities"]["tools"].is_object());
    m.send(json!({"jsonrpc":"2.0","method":"notifications/initialized"}));

    let r = m.rpc(2, "tools/list", json!({}));
    let tools = r["result"]["tools"].as_array().unwrap();
    let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
    assert_eq!(
        names,
        ["start_focus", "start_break", "pause", "resume", "stop", "skip", "extend", "reset", "label_block", "get_status", "list_blocks", "get_stats", "get_devices"]
    );
    for t in tools {
        assert!(!t["description"].as_str().unwrap().is_empty());
        assert_eq!(t["inputSchema"]["type"], "object");
    }
    let sf = tools.iter().find(|t| t["name"] == "start_focus").unwrap();
    assert!(sf["inputSchema"]["properties"]["minutes"]["description"].is_string());

    let res = m.tool("start_focus", json!({"minutes": 1, "label": "mcp"}));
    assert_eq!(res["isError"], false);
    let body: Value = serde_json::from_str(res["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(body["event"]["source"], "agent:claude-code");
    assert_eq!(body["timer"]["block"]["label"], "mcp");

    let res = m.tool("get_status", json!({}));
    let body: Value = serde_json::from_str(res["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(body["timer"]["status"], "running");

    // A failed command is a tool error carrying the API message.
    let res = m.tool("resume", json!({}));
    assert_eq!(res["isError"], true);
    assert!(res["content"][0]["text"].as_str().unwrap().contains("no paused block"));
    let res = m.tool("extend", json!({"minutes": -1}));
    assert_eq!(res["isError"], true);
    let res = m.tool("start_break", json!({"kind": "medium"}));
    assert_eq!(res["isError"], true);
    let res = m.tool("list_blocks", json!({"since": "24h", "limit": 3}));
    assert_eq!(res["isError"], false);
    let res = m.tool("list_blocks", json!({"since": "nonsense"}));
    assert_eq!(res["isError"], true);
    let res = m.tool("get_stats", json!({"group_by": "label"}));
    assert_eq!(res["isError"], false);
    let res = m.tool("stop", json!({}));
    assert_eq!(res["isError"], false);

    let r = m.rpc(5, "nope/method", json!({}));
    assert_eq!(r["error"]["code"], -32601);
}

#[test]
fn mcp_source_falls_back_to_agent_mcp() {
    let e = Env::new();
    let mut m = Mcp::spawn(e.tmp.path());
    let res = m.tool("start_break", json!({"kind": "short"}));
    let body: Value = serde_json::from_str(res["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(body["event"]["source"], "agent:mcp");
    assert_eq!(body["event"]["payload"]["planned_ms"], 300000);
}

#[test]
fn devices_pair_sync_and_revoke_commands() {
    let a = Env::with(SyncMode::Local, "alpha");
    let b = Env::with(SyncMode::Local, "beta");

    // Human `pair offer`: instructions, a QR code made of half blocks, and the ticket on its own line.
    let (code, out, err) = a.pomo(&["pair", "offer"]);
    assert_eq!(code, 0, "{err}");
    assert!(out.contains('\u{2580}') || out.contains('\u{2584}') || out.contains('\u{2588}'), "no QR code in:\n{out}");
    let human_ticket = out.lines().find(|l| l.starts_with("pomo-pair:")).expect("ticket line").to_string();
    // --json prints exactly the API body: no QR, one object.
    let offer = a.json(&["pair", "offer"]);
    let ticket = offer["ticket"].as_str().unwrap().to_string();
    assert_ne!(ticket, human_ticket, "every offer is a new single-use ticket");
    assert!(offer["expires_ms"].as_i64().unwrap() > 0);

    let (code, _, err) = b.pomo(&["pair", "join", "pomo-pair:garbage"]);
    assert_eq!(code, 1);
    assert!(err.contains("bad ticket"), "{err}");

    let (code, out, err) = b.pomo(&["pair", "join", &ticket]);
    assert_eq!(code, 0, "{err}");
    assert!(out.contains("paired:") && out.contains("alpha") && out.contains(&a.device_id()), "{out}");

    let d = a.json(&["devices"]);
    assert_eq!((d["name"].as_str(), d["device_id"].as_str()), (Some("alpha"), Some(a.device_id().as_str())));
    assert_eq!(d["devices"][0]["device_id"], json!(b.device_id()));
    assert_eq!(d["devices"][0]["paired"], true);
    let (_, out, _) = a.pomo(&["devices"]);
    assert!(out.contains("this device: alpha") && out.contains("beta") && out.contains("paired"), "{out}");

    // A starts a block; B shows it.
    a.json(&["start", "--minutes", "10", "--label", "shared"]);
    let mut shared = false;
    for _ in 0..60 {
        let st = b.json(&["status"]);
        if st["timer"]["block"]["label"] == "shared" {
            assert_eq!(st["timer"]["block"]["device_id"], json!(a.device_id()));
            shared = true;
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    assert!(shared, "B never showed A's block");
    let (_, out, _) = b.pomo(&["status"]);
    assert!(out.contains("running focus \"shared\""), "{out}");

    let r = b.json(&["sync", "--device", &a.device_id()]);
    assert_eq!(r["synced"][0]["device_id"], json!(a.device_id()));
    assert!(r["synced"][0]["error"].is_null(), "{r}");
    let (code, out, err) = b.pomo(&["sync"]);
    assert_eq!(code, 0, "{err}");
    assert!(out.contains("sent") && out.contains("received"), "{out}");
    let (code, _, err) = b.pomo(&["sync", "--device", "nope"]);
    assert_eq!(code, 1);
    assert!(err.contains("unknown device"), "{err}");

    let r = b.json(&["revoke", &a.device_id()]);
    assert_eq!((r["device"]["revoked"].as_bool(), r["device"]["paired"].as_bool()), (Some(true), Some(false)));
    let (_, out, _) = b.pomo(&["devices"]);
    assert!(out.contains("revoked"), "{out}");
    let (code, _, err) = b.pomo(&["revoke", "nope"]);
    assert_eq!(code, 1);
    assert!(err.contains("unknown device"), "{err}");
}

#[test]
fn device_commands_fail_cleanly_when_sync_is_off() {
    let e = Env::new();
    for args in [&["devices"][..], &["pair", "offer"], &["sync"], &["revoke", "x"], &["pair", "join", "pomo-pair:x"]] {
        let (code, _, err) = e.pomo(args);
        assert_eq!(code, 1, "{args:?}");
        assert!(err.contains("sync is off"), "{args:?}: {err}");
    }
}

#[test]
fn mcp_get_devices_is_read_only_and_listed() {
    let a = Env::with(SyncMode::Local, "alpha");
    let mut m = Mcp::spawn(a.tmp.path());
    let res = m.tool("get_devices", json!({}));
    assert_eq!(res["isError"], false);
    let body: Value = serde_json::from_str(res["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(body["name"], "alpha");
    assert!(body["devices"].as_array().unwrap().is_empty());
    for denied in ["pair_offer", "sync", "revoke_device"] {
        assert_eq!(m.tool(denied, json!({}))["isError"], true, "{denied}");
    }
}
