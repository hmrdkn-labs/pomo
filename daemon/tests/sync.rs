//! Two in-process `pomod` instances on `--sync local`, driven only through their HTTP APIs.

use std::io::{BufRead, BufReader};
use std::path::Path;
use std::sync::{mpsc, Arc};
use std::time::{Duration, Instant};

use pomod::{Daemon, Options, SyncMode};
use serde_json::{json, Value};
use tokio::runtime::Runtime;

struct Node {
    rt: Arc<Runtime>,
    daemon: Option<Daemon>,
    base: String,
    token: String,
    device_id: String,
}

impl Node {
    fn start(rt: &Arc<Runtime>, home: &Path, name: &str, sync: SyncMode, interval: Option<Duration>) -> Node {
        let opts = Options {
            port: 0,
            sync,
            name: Some(name.to_string()),
            sync_interval: interval,
            ..Options::new(home.to_path_buf())
        };
        let daemon = rt.block_on(Daemon::start(opts)).unwrap();
        Node {
            rt: rt.clone(),
            base: format!("http://{}", daemon.addr),
            token: daemon.token.clone(),
            device_id: daemon.device_id.clone(),
            daemon: Some(daemon),
        }
    }

    fn local(rt: &Arc<Runtime>, home: &Path, name: &str) -> Node {
        Node::start(rt, home, name, SyncMode::Local, None)
    }

    fn stop(&mut self) {
        if let Some(d) = self.daemon.take() {
            self.rt.block_on(d.shutdown()).unwrap();
        }
    }

    fn call(&self, method: &str, path: &str, body: Option<Value>) -> (u16, Value) {
        let r = agent()
            .request(method, &format!("{}{path}", self.base))
            .set("Authorization", &format!("Bearer {}", self.token))
            .timeout(Duration::from_secs(60));
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
        self.call("GET", path, None)
    }

    fn post(&self, path: &str, body: Value) -> (u16, Value) {
        self.call("POST", path, Some(body))
    }

    fn start_block(&self, label: &str) -> Value {
        let (c, r) = self.post("/v1/commands", json!({"type":"start","kind":"focus","planned_ms":600_000,"label":label}));
        assert_eq!(c, 200, "{r}");
        r["event"].clone()
    }

    fn block_id(&self) -> Option<String> {
        self.get("/v1/status").1["timer"]["block"]["id"].as_str().map(str::to_string)
    }

    fn event_ids(&self) -> Vec<String> {
        let (_, r) = self.get("/v1/events");
        r["events"].as_array().unwrap().iter().map(|e| e["id"].as_str().unwrap().to_string()).collect()
    }

    fn stream(&self) -> mpsc::Receiver<(String, String)> {
        let resp = agent()
            .get(&format!("{}/v1/stream", self.base))
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

    /// Pairs `self` (the joiner) with `offerer` through the HTTP endpoints.
    fn pair_with(&self, offerer: &Node) -> Value {
        let (c, offer) = offerer.post("/v1/pair/offer", json!({}));
        assert_eq!(c, 200, "{offer}");
        assert!(offer["ticket"].as_str().unwrap().starts_with("pomo-pair:"));
        let (c, joined) = self.post("/v1/pair/join", json!({"ticket": offer["ticket"]}));
        assert_eq!(c, 200, "{joined}");
        joined
    }
}

impl Drop for Node {
    fn drop(&mut self) {
        self.stop();
    }
}

/// No connection pooling: on macOS a pooled connection the server already closed fails the next
/// request with EINVAL.
fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new().max_idle_connections(0).build()
}

fn eventually(what: &str, within: Duration, mut f: impl FnMut() -> bool) {
    let t = Instant::now();
    while !f() {
        assert!(t.elapsed() < within, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn runtime() -> Arc<Runtime> {
    Arc::new(tokio::runtime::Builder::new_multi_thread().worker_threads(4).enable_all().build().unwrap())
}

#[test]
fn pair_sync_stream_and_revoke() {
    let rt = runtime();
    let (ta, tb) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let a = Node::local(&rt, ta.path(), "alpha");
    let b = Node::local(&rt, tb.path(), "beta");
    assert_ne!(a.device_id, b.device_id);
    let b_stream = b.stream();

    // Pair: A joins B's ticket (so A also learns B's address for the dial-back below).
    let joined = a.pair_with(&b);
    assert_eq!(joined["device"], json!({"device_id": b.device_id, "name": "beta", "paired": true, "revoked": false}));
    let (_, devs) = b.get("/v1/devices");
    assert_eq!((devs["device_id"].as_str(), devs["name"].as_str()), (Some(b.device_id.as_str()), Some("beta")));
    assert_eq!(
        devs["devices"],
        json!([{"device_id": a.device_id, "name": "alpha", "paired": true, "revoked": false}]),
        "own device is not listed; the joiner is paired on the offering side too"
    );

    // A starts a block; B sees it in /v1/status and on its stream within 3 s.
    let started = a.start_block("deep work");
    let started_id = started["id"].as_str().unwrap().to_string();
    let seen = Instant::now();
    let mut on_stream = false;
    while seen.elapsed() < Duration::from_secs(3) {
        if let Ok((name, data)) = b_stream.recv_timeout(Duration::from_millis(100)) {
            if name == "pomo.event" && serde_json::from_str::<Value>(&data).unwrap()["id"] == started["id"] {
                on_stream = true;
                break;
            }
        }
    }
    assert!(on_stream, "A's event was not published on B's /v1/stream within 3 s");
    let (_, st) = b.get("/v1/status");
    assert_eq!(st["timer"]["status"], "running");
    let block = &st["timer"]["block"];
    assert_eq!((block["label"].as_str(), block["device_id"].as_str()), (Some("deep work"), Some(a.device_id.as_str())));
    let block_id = block["id"].as_str().unwrap().to_string();
    assert_eq!(a.block_id().as_deref(), Some(block_id.as_str()));
    assert!(b.event_ids().contains(&started_id));

    // Both directions over the live session: B pauses, A follows.
    let (c, _) = b.post("/v1/commands", json!({"type": "pause"}));
    assert_eq!(c, 200);
    eventually("pause on A", Duration::from_secs(3), || a.get("/v1/status").1["timer"]["status"] == "paused");

    // B revokes A: A's later events never arrive on B.
    let (c, r) = b.post(&format!("/v1/devices/{}/revoke", a.device_id), json!({}));
    assert_eq!(c, 200, "{r}");
    assert_eq!(r["device"]["revoked"], true);
    assert_eq!(r["device"]["paired"], false);
    let before = b.event_ids();
    a.post("/v1/commands", json!({"type": "resume"}));
    let after_revoke = a.start_block("after revoke");
    std::thread::sleep(Duration::from_millis(1200));
    assert_eq!(b.event_ids(), before);
    assert!(!b.event_ids().contains(&after_revoke["id"].as_str().unwrap().to_string()));
    assert_eq!(b.block_id().as_deref(), Some(block_id.as_str()), "B's timer must not follow A any more");
    // A dialing B again is rejected by B; B refuses to dial A.
    let (c, r) = a.post("/v1/sync", json!({"device_id": b.device_id}));
    assert_eq!(c, 200);
    let err = r["synced"][0]["error"].as_str().unwrap_or_default();
    assert!(err.contains("revoked") || err.contains("rejected"), "{r}");
    let (c, r) = b.post("/v1/sync", json!({"device_id": a.device_id}));
    assert_eq!(c, 409, "{r}");
    assert_eq!(r["error"]["code"], "invalid_state");
    let (_, devs) = b.get("/v1/devices");
    assert_eq!(devs["devices"][0]["revoked"], true);
}

#[test]
fn manual_sync_reports_counts_and_unknown_devices() {
    let rt = runtime();
    let (ta, tb) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let a = Node::local(&rt, ta.path(), "alpha");
    let b = Node::local(&rt, tb.path(), "beta");
    // Events from before pairing travel in the pairing session.
    a.start_block("old");
    b.pair_with(&a);
    assert_eq!(b.event_ids(), a.event_ids());

    let (c, r) = b.post("/v1/sync", json!({}));
    assert_eq!(c, 200, "{r}");
    assert_eq!(r["synced"], json!([{"device_id": a.device_id, "sent": 0, "received": 0}]));
    let (c, r) = a.post("/v1/sync", json!({}));
    assert_eq!(c, 200);
    // A learned B only from the handshake, so it has no address to dial: reported, not an HTTP error.
    assert_eq!(r["synced"], json!([]), "{r}");
    let (c, r) = a.post("/v1/sync", json!({"device_id": b.device_id}));
    assert_eq!(c, 200);
    assert_eq!(r["synced"][0]["device_id"], json!(b.device_id));
    assert!(r["synced"][0]["error"].is_string());
    let (c, r) = a.post("/v1/sync", json!({"device_id": "nope"}));
    assert_eq!(c, 404, "{r}");
    assert_eq!(r["error"]["code"], "not_found");
    let (c, r) = a.post(&format!("/v1/devices/{}/revoke", "nope"), json!({}));
    assert_eq!(c, 404, "{r}");
    let (c, r) = a.post(&format!("/v1/devices/{}/revoke", a.device_id), json!({}));
    assert_eq!(c, 400, "{r}");
}

#[test]
fn join_errors_are_typed() {
    let rt = runtime();
    let tmp: Vec<_> = (0..3).map(|_| tempfile::tempdir().unwrap()).collect();
    let a = Node::local(&rt, tmp[0].path(), "alpha");
    let b = Node::local(&rt, tmp[1].path(), "beta");
    let c = Node::local(&rt, tmp[2].path(), "gamma");

    let (code, r) = b.post("/v1/pair/join", json!({"ticket": "garbage"}));
    assert_eq!((code, r["error"]["code"].as_str()), (400, Some("bad_ticket")), "{r}");
    let (code, r) = b.post("/v1/pair/join", json!({}));
    assert_eq!((code, r["error"]["code"].as_str()), (400, Some("bad_request")), "{r}");

    let (_, offer) = a.post("/v1/pair/offer", json!({}));
    assert!(offer["expires_ms"].as_i64().unwrap() > 0);
    let (code, r) = b.post("/v1/pair/join", json!({"ticket": offer["ticket"], "name": "beta laptop"}));
    assert_eq!(code, 200, "{r}");
    let (_, devs) = a.get("/v1/devices");
    assert_eq!(devs["devices"][0]["name"], "beta laptop", "the name override reaches the offerer");
    // The ticket is single use.
    let (code, r) = c.post("/v1/pair/join", json!({"ticket": offer["ticket"]}));
    assert_eq!((code, r["error"]["code"].as_str()), (409, Some("pairing_rejected")), "{r}");
    assert!(r["error"]["message"].as_str().unwrap().contains("used"), "{r}");
    assert!(c.get("/v1/devices").1["devices"].as_array().unwrap().is_empty());
}

#[test]
fn sync_endpoints_answer_501_when_sync_is_off() {
    let rt = runtime();
    let tmp = tempfile::tempdir().unwrap();
    let d = Node::start(&rt, tmp.path(), "solo", SyncMode::Off, None);
    for (method, path) in [
        ("GET", "/v1/devices"),
        ("POST", "/v1/pair/offer"),
        ("POST", "/v1/pair/join"),
        ("POST", "/v1/sync"),
        ("POST", "/v1/devices/abc/revoke"),
    ] {
        let (code, r) = d.call(method, path, (method == "POST").then(|| json!({})));
        assert_eq!((code, r["error"]["code"].as_str()), (501, Some("sync_disabled")), "{method} {path}: {r}");
    }
    // The timer works and the id is still the key's endpoint id.
    d.start_block("x");
    assert_eq!(d.get("/v1/status").1["timer"]["block"]["device_id"], json!(d.device_id));
}

#[test]
fn restart_then_sync_by_device_id_uses_the_persisted_address() {
    let rt = runtime();
    let (ta, tb) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let mut a = Node::local(&rt, ta.path(), "alpha");
    let b = Node::local(&rt, tb.path(), "beta");
    let a_id = a.device_id.clone();
    // A joins B's ticket, so A learns B's address.
    let joined = a.pair_with(&b);
    assert_eq!(joined["device"]["device_id"], json!(b.device_id));
    a.start_block("before restart");
    eventually("A's block on B", Duration::from_secs(3), || b.block_id().is_some());

    a.stop();
    let while_down = b.call("POST", "/v1/commands", Some(json!({"type": "stop"}))).1["event"]["id"].clone();
    assert!(while_down.is_string());

    // New process, same home: same device id, no sync until asked.
    let a = Node::local(&rt, ta.path(), "alpha");
    assert_eq!(a.device_id, a_id);
    assert!(!a.event_ids().contains(&while_down.as_str().unwrap().to_string()));
    let (c, r) = a.post("/v1/sync", json!({"device_id": b.device_id}));
    assert_eq!(c, 200, "{r}");
    assert_eq!(r["synced"][0]["device_id"], json!(b.device_id));
    assert_eq!(r["synced"][0]["error"], Value::Null, "{r}");
    assert_eq!(r["synced"][0]["received"], 1);
    assert_eq!(a.get("/v1/status").1["timer"]["status"], "idle");
    assert_eq!(a.event_ids(), b.event_ids());
    // And the other direction still flows live over the new session.
    let fresh = a.start_block("after restart");
    eventually("fresh block on B", Duration::from_secs(3), || b.event_ids().contains(&fresh["id"].as_str().unwrap().to_string()));
}

#[test]
fn background_sync_reconnects_to_paired_devices_without_being_asked() {
    let rt = runtime();
    let (ta, tb) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let mut a = Node::local(&rt, ta.path(), "alpha");
    let b = Node::local(&rt, tb.path(), "beta");
    a.pair_with(&b);
    a.stop();
    let missed = b.start_block("while A was down");

    let a = Node::start(&rt, ta.path(), "alpha", SyncMode::Local, Some(Duration::from_millis(300)));
    eventually("background sync on A", Duration::from_secs(5), || {
        a.event_ids().contains(&missed["id"].as_str().unwrap().to_string())
    });
    assert_eq!(a.block_id(), b.block_id());
}
