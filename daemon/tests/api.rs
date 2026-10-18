use std::io::{BufRead, BufReader};
use std::sync::mpsc;
use std::time::Duration;

use pomod::{Daemon, Options};
use serde_json::{json, Value};

struct Td {
    rt: tokio::runtime::Runtime,
    daemon: Option<Daemon>,
    tmp: tempfile::TempDir,
    base: String,
    token: String,
}

impl Td {
    fn new() -> Td {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        let daemon = rt
            .block_on(Daemon::start(Options { home: tmp.path().to_path_buf(), port: 0 }))
            .unwrap();
        let base = format!("http://{}", daemon.addr);
        let token = daemon.token.clone();
        Td { rt, daemon: Some(daemon), tmp, base, token }
    }

    fn call(&self, method: &str, path: &str, body: Option<Value>, headers: &[(&str, &str)], token: Option<&str>) -> (u16, Value) {
        let mut r = ureq::request(method, &format!("{}{path}", self.base));
        if let Some(t) = token {
            r = r.set("Authorization", &format!("Bearer {t}"));
        }
        for (k, v) in headers {
            r = r.set(k, v);
        }
        let res = match body {
            Some(b) => r.send_json(b),
            None => r.call(),
        };
        match res {
            Ok(resp) => (resp.status(), resp.into_json().unwrap()),
            Err(ureq::Error::Status(c, resp)) => (c, resp.into_json().unwrap_or(Value::Null)),
            Err(e) => panic!("transport: {e}"),
        }
    }

    fn get(&self, path: &str) -> (u16, Value) {
        self.call("GET", path, None, &[], Some(&self.token))
    }

    fn cmd(&self, body: Value) -> (u16, Value) {
        self.call("POST", "/v1/commands", Some(body), &[], Some(&self.token))
    }

    fn stream(&self) -> mpsc::Receiver<(String, String)> {
        let resp = ureq::get(&format!("{}/v1/stream", self.base))
            .set("Authorization", &format!("Bearer {}", self.token))
            .call()
            .unwrap();
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let mut name = String::new();
            for line in BufReader::new(resp.into_reader()).lines() {
                let Ok(line) = line else { return };
                if let Some(n) = line.strip_prefix("event:") {
                    name = n.trim().to_string();
                } else if let Some(d) = line.strip_prefix("data:") {
                    if tx.send((name.clone(), d.trim().to_string())).is_err() {
                        return;
                    }
                }
            }
        });
        rx
    }
}

impl Drop for Td {
    fn drop(&mut self) {
        if let Some(d) = self.daemon.take() {
            let _ = self.rt.block_on(d.shutdown());
        }
    }
}

fn start(planned_ms: i64, label: Option<&str>) -> Value {
    let mut b = json!({"type": "start", "kind": "focus", "planned_ms": planned_ms});
    if let Some(l) = label {
        b["label"] = json!(l);
    }
    b
}

#[test]
fn full_timer_flow() {
    let td = Td::new();
    let (c, st) = td.get("/v1/status");
    assert_eq!(c, 200);
    assert_eq!(st["timer"]["status"], "idle");
    assert!(st["timer"]["block"].is_null());
    assert!(st["timer"]["remaining_ms"].is_null());
    assert_eq!(st["timer"]["next_kind"], "focus");

    let (c, r) = td.cmd(json!({"type":"start","kind":"focus","planned_ms":60000,"label":"x","project":"p"}));
    assert_eq!(c, 200);
    assert_eq!(r["replayed"], false);
    assert_eq!(r["event"]["type"], "timer.started");
    assert_eq!(r["event"]["source"], "user");
    assert_eq!(r["timer"]["status"], "running");
    let block = &r["timer"]["block"];
    assert_eq!(block["label"], "x");
    assert_eq!(block["project"], "p");
    assert_eq!(block["phase"], "running");
    assert!(block["outcome"].is_null() && block["ended_ms"].is_null());
    let id = block["id"].as_str().unwrap().to_string();
    assert!(r["timer"]["remaining_ms"].as_i64().unwrap() <= 60000);

    let (_, r) = td.cmd(json!({"type":"pause"}));
    assert_eq!(r["timer"]["status"], "paused");
    let (_, r) = td.cmd(json!({"type":"resume"}));
    assert_eq!(r["timer"]["status"], "running");
    let (_, r) = td.cmd(json!({"type":"extend","add_ms":30000}));
    assert_eq!(r["timer"]["block"]["planned_ms"], 90000);
    let (_, r) = td.cmd(json!({"type":"label","label":"y"}));
    assert_eq!(r["event"]["type"], "block.labeled");
    assert_eq!(r["timer"]["block"]["label"], "y");
    let (_, r) = td.cmd(json!({"type":"stop"}));
    assert_eq!(r["timer"]["status"], "idle");

    let (c, b) = td.get("/v1/blocks");
    assert_eq!(c, 200);
    let blocks = b["blocks"].as_array().unwrap();
    assert_eq!(blocks.len(), 1);
    assert_eq!(blocks[0]["id"], id);
    assert_eq!(blocks[0]["outcome"], "abandoned");
    assert_eq!(blocks[0]["phase"], "ended");
    assert!(blocks[0]["ended_ms"].is_i64());
    assert_eq!(blocks[0]["label"], "y");

    let (_, b) = td.get("/v1/blocks?kind=short_break");
    assert!(b["blocks"].as_array().unwrap().is_empty());
    assert_eq!(td.get("/v1/blocks?kind=nope").0, 400);
    assert_eq!(td.get("/v1/blocks?limit=0").0, 400);

    let (c, e) = td.get("/v1/events");
    assert_eq!(c, 200);
    let types: Vec<&str> = e["events"].as_array().unwrap().iter().map(|e| e["type"].as_str().unwrap()).collect();
    assert_eq!(
        types,
        ["timer.started", "timer.paused", "timer.resumed", "timer.extended", "block.labeled", "timer.stopped"]
    );
    let vv = serde_json::to_string(&json!({e["events"][0]["device_id"].as_str().unwrap(): 4})).unwrap();
    let url_vv: String = vv.bytes().map(|c| format!("%{c:02X}")).collect();
    let (_, e2) = td.get(&format!("/v1/events?after={url_vv}"));
    assert_eq!(e2["events"].as_array().unwrap().len(), 2);
}

#[test]
fn idempotency_key_replays() {
    let td = Td::new();
    let h = [("Idempotency-Key", "k1")];
    let (_, a) = td.call("POST", "/v1/commands", Some(start(60000, None)), &h, Some(&td.token));
    let (c, b) = td.call("POST", "/v1/commands", Some(start(60000, None)), &h, Some(&td.token));
    assert_eq!(c, 200);
    assert_eq!(a["replayed"], false);
    assert_eq!(b["replayed"], true);
    assert_eq!(a["event"]["id"], b["event"]["id"]);
    assert_eq!(td.get("/v1/blocks").1["blocks"].as_array().unwrap().len(), 1);
    // Without a key each request is a new command.
    td.cmd(start(60000, None));
    assert_eq!(td.get("/v1/blocks").1["blocks"].as_array().unwrap().len(), 2);
}

#[test]
fn auth_is_required_on_every_endpoint() {
    let td = Td::new();
    for (m, p) in [("GET", "/v1/status"), ("POST", "/v1/commands"), ("GET", "/v1/blocks"), ("GET", "/v1/stats"), ("GET", "/v1/events"), ("GET", "/v1/stream")] {
        let body = (m == "POST").then(|| json!({"type":"pause"}));
        let (c, b) = td.call(m, p, body.clone(), &[], None);
        assert_eq!(c, 401, "{p} without token");
        assert_eq!(b["error"]["code"], "unauthorized");
        let (c, _) = td.call(m, p, body, &[], Some("wrong"));
        assert_eq!(c, 401, "{p} wrong token");
    }
    assert_eq!(td.get("/v1/nope").0, 404);
    // The token file is private and matches.
    use std::os::unix::fs::PermissionsExt;
    let f = td.tmp.path().join("token");
    assert_eq!(std::fs::metadata(&f).unwrap().permissions().mode() & 0o777, 0o600);
    assert_eq!(std::fs::read_to_string(&f).unwrap().trim(), td.token);
}

#[test]
fn invalid_commands_are_400_or_409_and_write_nothing() {
    let td = Td::new();
    let (c, b) = td.cmd(json!({"type":"pause"}));
    assert_eq!(c, 409);
    assert_eq!(b["error"]["code"], "invalid_state");
    assert_eq!(td.cmd(json!({"type":"stop"})).0, 409);
    assert_eq!(td.cmd(json!({"type":"extend","add_ms":1000})).0, 409);
    assert_eq!(td.cmd(json!({"type":"start","kind":"focus","planned_ms":0})).0, 400);
    assert_eq!(td.cmd(json!({"type":"bogus"})).0, 400);
    assert_eq!(td.cmd(json!({"type":"start"})).0, 400);
    let (c, b) = td.cmd(json!({"type":"label","label":"z","block_id":"nope"}));
    assert_eq!((c, b["error"]["code"].as_str()), (404, Some("not_found")));
    assert_eq!(td.get("/v1/events").1["events"].as_array().unwrap().len(), 0);
}

#[test]
fn source_header_sets_event_and_block_source() {
    let td = Td::new();
    let (c, r) = td.call("POST", "/v1/commands", Some(start(60000, None)), &[("X-Pomo-Source", "agent:claude-code")], Some(&td.token));
    assert_eq!(c, 200);
    assert_eq!(r["event"]["source"], "agent:claude-code");
    assert_eq!(r["timer"]["block"]["source"], "agent:claude-code");
    for bad in ["agent:Bad Name", "agent:", "robot", &format!("agent:{}", "a".repeat(33))] {
        let (c, _) = td.call("POST", "/v1/commands", Some(start(60000, None)), &[("X-Pomo-Source", bad)], Some(&td.token));
        assert_eq!(c, 400, "{bad}");
    }
}

#[test]
fn stats_group_by_day_label_project() {
    let td = Td::new();
    let run = |label: Option<&str>, project: Option<&str>, ms: i64| {
        let mut b = start(ms, label);
        if let Some(p) = project {
            b["project"] = json!(p);
        }
        td.cmd(b);
        std::thread::sleep(Duration::from_millis(ms as u64 + 60));
    };
    run(Some("a"), Some("p1"), 100);
    run(Some("b"), Some("p1"), 250);
    run(None, None, 100);
    run(Some("a"), Some("p2"), 100);
    td.cmd(json!({"type":"start","kind":"short_break","planned_ms":100}));
    std::thread::sleep(Duration::from_millis(160));

    let (c, s) = td.get("/v1/stats?group_by=label&tz_offset_min=0");
    assert_eq!(c, 200);
    assert_eq!(s["focus_ms"], 550);
    assert_eq!(s["completed_focus"], 4);
    assert_eq!(s["tz_offset_min"], 0);
    assert_eq!(s["streak_days"], 1);
    let g = s["groups"].as_array().unwrap();
    let got: Vec<(&str, i64, i64)> = g.iter().map(|g| (g["key"].as_str().unwrap(), g["focus_ms"].as_i64().unwrap(), g["completed_focus"].as_i64().unwrap())).collect();
    assert_eq!(got, [("b", 250, 1), ("a", 200, 2), ("", 100, 1)]);

    let (_, s) = td.get("/v1/stats?group_by=project");
    let got: Vec<(&str, i64)> = s["groups"].as_array().unwrap().iter().map(|g| (g["key"].as_str().unwrap(), g["focus_ms"].as_i64().unwrap())).collect();
    assert_eq!(got, [("p1", 350), ("", 100), ("p2", 100)]);

    let (_, s) = td.get("/v1/stats?tz_offset_min=0");
    let g = s["groups"].as_array().unwrap();
    assert_eq!(g.len(), 1);
    let key = g[0]["key"].as_str().unwrap();
    assert_eq!(key.len(), 10);
    assert_eq!(g[0]["focus_ms"], 550);
    // A far-away timezone still yields one valid day key and shifts nothing else.
    assert_eq!(td.get("/v1/stats?tz_offset_min=840").1["focus_ms"], 550);

    assert_eq!(td.get("/v1/stats?group_by=nope").0, 400);
    assert_eq!(td.get("/v1/stats?tz_offset_min=abc").0, 400);
    let (_, s) = td.get("/v1/stats?from_ms=99999999999999");
    assert_eq!(s["focus_ms"], 0);

    let (_, st) = td.get("/v1/status?tz_offset_min=0");
    assert_eq!(st["today"]["focus_ms"], 550);
    assert_eq!(st["today"]["completed_focus"], 4);
}

#[test]
fn stream_delivers_events_and_block_end() {
    let td = Td::new();
    let rx = td.stream();
    let (_, r) = td.call("POST", "/v1/commands", Some(start(300, Some("s"))), &[("X-Pomo-Source", "agent:t")], Some(&td.token));
    let block_id = r["timer"]["block"]["id"].as_str().unwrap().to_string();
    let (name, data) = rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(name, "pomo.event");
    let ev: Value = serde_json::from_str(&data).unwrap();
    assert_eq!(ev["id"], r["event"]["id"]);
    assert_eq!(ev["source"], "agent:t");

    let t0 = std::time::Instant::now();
    let (name, data) = rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(name, "pomo.block_end");
    let be: Value = serde_json::from_str(&data).unwrap();
    assert_eq!(be["block_id"], block_id);
    assert_eq!(be["outcome"], "completed");
    assert_eq!(be["ended_ms"], r["timer"]["block"]["started_ms"].as_i64().unwrap() + 300);
    assert!(t0.elapsed() < Duration::from_millis(1500));
    // block_end writes no event.
    assert_eq!(td.get("/v1/events").1["events"].as_array().unwrap().len(), 1);
}

#[test]
fn block_end_is_rescheduled_by_commands() {
    let td = Td::new();
    let rx = td.stream();
    td.cmd(start(300, None));
    rx.recv_timeout(Duration::from_secs(2)).unwrap();
    // Extending moves the end: no block_end at the old time.
    td.cmd(json!({"type":"extend","add_ms":600}));
    assert_eq!(rx.recv_timeout(Duration::from_secs(2)).unwrap().0, "pomo.event");
    assert!(rx.recv_timeout(Duration::from_millis(500)).is_err(), "stale block_end fired");
    let (name, _) = rx.recv_timeout(Duration::from_secs(3)).unwrap();
    assert_eq!(name, "pomo.block_end");
    // Stopping cancels the timer.
    td.cmd(start(300, None));
    rx.recv_timeout(Duration::from_secs(2)).unwrap();
    td.cmd(json!({"type":"stop"}));
    assert_eq!(rx.recv_timeout(Duration::from_secs(2)).unwrap().0, "pomo.event");
    assert!(rx.recv_timeout(Duration::from_millis(600)).is_err());
}

#[test]
fn shutdown_removes_daemon_json_and_ends_streams() {
    let mut td = Td::new();
    let dj = td.tmp.path().join("daemon.json");
    let v: Value = serde_json::from_str(&std::fs::read_to_string(&dj).unwrap()).unwrap();
    assert_eq!(v["port"], td.daemon.as_ref().unwrap().addr.port());
    assert_eq!(v["pid"], std::process::id());
    let rx = td.stream();
    let d = td.daemon.take().unwrap();
    td.rt.block_on(d.shutdown()).unwrap();
    assert!(!dj.exists());
    assert!(rx.recv_timeout(Duration::from_secs(2)).is_err());
}

#[test]
fn state_survives_restart() {
    let tmp = tempfile::tempdir().unwrap();
    let rt = tokio::runtime::Runtime::new().unwrap();
    let go = |f: &dyn Fn(&str, &str)| {
        let d = rt.block_on(Daemon::start(Options { home: tmp.path().to_path_buf(), port: 0 })).unwrap();
        f(&format!("http://{}", d.addr), &d.token);
        rt.block_on(d.shutdown()).unwrap();
    };
    go(&|base, token| {
        ureq::post(&format!("{base}/v1/commands")).set("Authorization", &format!("Bearer {token}")).send_json(start(600000, Some("keep"))).unwrap();
    });
    go(&|base, token| {
        let st: Value = ureq::get(&format!("{base}/v1/status")).set("Authorization", &format!("Bearer {token}")).call().unwrap().into_json().unwrap();
        assert_eq!(st["timer"]["status"], "running");
        assert_eq!(st["timer"]["block"]["label"], "keep");
    });
}
