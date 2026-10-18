//! Regression tests for the review findings that touch the Daemon: overflow through the API
//! (R3-1), Host/Origin/content-type checks (R2-1), SSE resync and stream cap (R2-2), token and
//! daemon.json permissions (R2-3), the single-instance lock (A8) and `/v1/events` paging (A9, R2-4).

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::os::unix::fs::PermissionsExt;
use std::time::{Duration, Instant};

use pomod::{Daemon, Options, SyncMode};
use serde_json::{json, Value};

struct Td {
    rt: tokio::runtime::Runtime,
    daemon: Option<Daemon>,
    tmp: tempfile::TempDir,
    base: String,
    token: String,
    addr: SocketAddr,
}

fn opts(home: &std::path::Path) -> Options {
    Options { port: 0, sync: SyncMode::Off, ..Options::new(home.to_path_buf()) }
}

impl Td {
    fn new() -> Td {
        Td::in_home(tempfile::tempdir().unwrap())
    }

    fn in_home(tmp: tempfile::TempDir) -> Td {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let daemon = rt.block_on(Daemon::start(opts(tmp.path()))).unwrap();
        let (addr, token) = (daemon.addr, daemon.token.clone());
        Td { rt, daemon: Some(daemon), tmp, base: format!("http://{addr}"), token, addr }
    }

    fn call(&self, method: &str, path: &str, body: Option<Value>) -> (u16, Value) {
        let r = ureq::request(method, &format!("{}{path}", self.base))
            .set("Authorization", &format!("Bearer {}", self.token));
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

    fn cmd(&self, body: Value) -> (u16, Value) {
        self.call("POST", "/v1/commands", Some(body))
    }

    /// One raw HTTP/1.1 exchange; `extra` are header lines without CRLF.
    fn raw(&self, method: &str, path: &str, host: &str, extra: &[&str], body: Option<&str>) -> (u16, Value) {
        let mut req = format!("{method} {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n");
        for h in extra {
            req.push_str(h);
            req.push_str("\r\n");
        }
        match body {
            Some(b) => req.push_str(&format!("Content-Length: {}\r\n\r\n{b}", b.len())),
            None => req.push_str("\r\n"),
        }
        let mut s = TcpStream::connect(self.addr).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        s.write_all(req.as_bytes()).unwrap();
        let mut out = String::new();
        s.read_to_string(&mut out).unwrap();
        let status: u16 = out[9..12].parse().unwrap();
        let body = out.split_once("\r\n\r\n").map_or("", |(_, b)| b);
        (status, serde_json::from_str(body).unwrap_or(Value::Null))
    }

    fn auth(&self) -> String {
        format!("Authorization: Bearer {}", self.token)
    }
}

impl Drop for Td {
    fn drop(&mut self) {
        if let Some(d) = self.daemon.take() {
            let _ = self.rt.block_on(d.shutdown());
        }
    }
}

fn start(planned_ms: i64) -> Value {
    json!({"type": "start", "kind": "focus", "planned_ms": planned_ms})
}

#[test]
fn r3_1_huge_durations_are_400_and_the_daemon_keeps_answering() {
    let td = Td::new();
    // The review's repro: this used to panic inside the reducer and answer 500 forever after.
    let (c, b) = td.cmd(start(i64::MAX));
    assert_eq!((c, b["error"]["code"].as_str()), (400, Some("bad_request")), "{b}");
    assert_eq!(td.get("/v1/status").0, 200);
    assert_eq!(td.get("/v1/blocks").0, 200);
    assert_eq!(td.cmd(start(86_400_001)).0, 400);
    assert_eq!(td.cmd(start(60_000)).0, 200);
    assert_eq!(td.cmd(json!({"type": "extend", "add_ms": i64::MAX})).0, 400);
    // Two legal extends are fine; the one past 48 h in total is refused.
    assert_eq!(td.cmd(json!({"type": "extend", "add_ms": 86_400_000})).0, 200);
    assert_eq!(td.cmd(json!({"type": "extend", "add_ms": 86_400_000})).0, 400);
    let (c, st) = td.get("/v1/status");
    assert_eq!(c, 200);
    assert_eq!(st["timer"]["block"]["planned_ms"], 86_460_000);
    assert_eq!(td.get("/v1/stats").0, 200);
}

#[test]
fn r2_1_host_origin_and_content_type_are_enforced() {
    let td = Td::new();
    let port = td.addr.port();
    let auth = td.auth();
    let ok_host = format!("127.0.0.1:{port}");
    let body = start(60_000).to_string();

    // Host: only this daemon's loopback name and port. The check comes before authentication.
    assert_eq!(td.raw("GET", "/v1/status", &ok_host, &[&auth], None).0, 200);
    assert_eq!(td.raw("GET", "/v1/status", &format!("localhost:{port}"), &[&auth], None).0, 200);
    for bad in ["evil.example.com", &format!("evil.example.com:{port}"), "127.0.0.1", "127.0.0.1:1", &format!("127.0.0.1.evil.com:{port}")] {
        let (c, b) = td.raw("GET", "/v1/status", bad, &[&auth], None);
        assert_eq!((c, b["error"]["code"].as_str()), (403, Some("bad_host")), "Host {bad}");
    }
    assert_eq!(td.raw("GET", "/v1/status", "evil.example.com", &[], None).0, 403, "no token needed to be refused");
    assert_eq!(td.raw("GET", "/v1/status", &ok_host, &[], None).0, 401);

    // Origin: any value is refused (browsers send it, native clients do not).
    for origin in ["http://evil.example.com", "null", "http://127.0.0.1"] {
        let h = format!("Origin: {origin}");
        let (c, b) = td.raw("GET", "/v1/status", &ok_host, &[&auth, &h], None);
        assert_eq!((c, b["error"]["code"].as_str()), (403, Some("bad_origin")), "Origin {origin}");
    }
    // The CORS "simple request" of the review: cross-site POST, text/plain, no preflight.
    let (c, _) = td.raw("POST", "/v1/commands", &ok_host, &[&auth, "Origin: http://evil.example.com", "Content-Type: text/plain"], Some(&body));
    assert_eq!(c, 403);
    assert_eq!(td.get("/v1/status").1["timer"]["status"], "idle", "nothing was executed");

    // Content type: JSON required on a POST with a body; parameters and case are fine.
    let (c, b) = td.raw("POST", "/v1/commands", &ok_host, &[&auth, "Content-Type: text/plain"], Some(&body));
    assert_eq!((c, b["error"]["code"].as_str()), (415, Some("unsupported_media_type")));
    assert_eq!(td.raw("POST", "/v1/commands", &ok_host, &[&auth], Some(&body)).0, 415, "no content type at all");
    assert_eq!(td.get("/v1/status").1["timer"]["status"], "idle");
    let (c, _) = td.raw("POST", "/v1/commands", &ok_host, &[&auth, "Content-Type: Application/JSON; charset=utf-8"], Some(&body));
    assert_eq!(c, 200);
    // A bodyless POST needs no content type (here: sync is off, so 501 from the handler).
    assert_eq!(td.raw("POST", "/v1/sync", &ok_host, &[&auth], None).0, 501);
}

#[test]
fn r2_2_stream_cap_is_16() {
    let td = Td::new();
    let open = || {
        ureq::get(&format!("{}/v1/stream", td.base))
            .set("Authorization", &format!("Bearer {}", td.token))
            .call()
            .map_err(Box::new)
    };
    let held: Vec<_> = (0..16).map(|_| open().unwrap()).collect();
    match open().map_err(|e| *e) {
        Err(ureq::Error::Status(503, r)) => {
            assert_eq!(r.into_json::<Value>().unwrap()["error"]["code"], "too_many_streams");
        }
        other => panic!("17th stream: {:?}", other.map(|r| r.status())),
    }
    drop(held);
}

#[test]
fn r2_2_a_lagging_stream_gets_pomo_resync() {
    let td = Td::new();
    let tail = td.rt.block_on(async {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        // A client with a tiny receive buffer that reads nothing while events pile up.
        let socket = tokio::net::TcpSocket::new_v4().unwrap();
        socket.set_recv_buffer_size(4096).unwrap();
        let mut s = socket.connect(td.addr).await.unwrap();
        let req = format!(
            "GET /v1/stream HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nAuthorization: Bearer {}\r\n\r\n",
            td.addr.port(),
            td.token
        );
        s.write_all(req.as_bytes()).await.unwrap();
        let mut head = [0u8; 12];
        s.read_exact(&mut head).await.unwrap();
        assert_eq!(&head, b"HTTP/1.1 200");
        s
    });
    // Far more than the 256-event buffer, each as large as an event may be.
    let label = "x".repeat(15_000);
    for i in 0..500 {
        let (c, b) = td.cmd(json!({"type": "start", "kind": "focus", "planned_ms": 60_000, "label": label, "command_key": format!("k{i}")}));
        assert_eq!(c, 200, "{b}");
    }
    let found = td.rt.block_on(async move {
        use tokio::io::AsyncReadExt;
        let mut s = tail;
        let mut seen = Vec::new();
        let mut chunk = vec![0u8; 64 * 1024];
        let deadline = Instant::now() + Duration::from_secs(20);
        while Instant::now() < deadline {
            match tokio::time::timeout(Duration::from_secs(2), s.read(&mut chunk)).await {
                Ok(Ok(n)) if n > 0 => {
                    // Only the event names matter; keep a rolling window to find them across reads.
                    seen.extend_from_slice(&chunk[..n]);
                    if let Some(at) = find(&seen, b"event: pomo.resync") {
                        let rest = String::from_utf8_lossy(&seen[at..seen.len().min(at + 200)]).to_string();
                        return Some(rest);
                    }
                    if seen.len() > 4 * 1024 * 1024 {
                        let keep = seen.split_off(seen.len() - 64);
                        seen = keep;
                    }
                }
                _ => break,
            }
        }
        None
    });
    let found = found.expect("no pomo.resync after the client fell behind");
    assert!(found.contains("\"missed\""), "{found}");
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

#[test]
fn r2_3_token_is_tightened_and_symlinks_are_refused() {
    // An existing token readable by others is chmod'ed to 0600 and still works.
    let home = tempfile::tempdir().unwrap();
    let token_path = home.path().join("token");
    std::fs::write(&token_path, "preexisting-token\n").unwrap();
    std::fs::set_permissions(&token_path, std::fs::Permissions::from_mode(0o644)).unwrap();
    let td = Td::in_home(home);
    assert_eq!(td.token, "preexisting-token");
    let mode = |p: &str| std::fs::metadata(td.tmp.path().join(p)).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode("token"), 0o600);
    assert_eq!(mode("daemon.json"), 0o600);
    assert_eq!(mode("daemon.lock"), 0o600);
    drop(td);

    // A token that is a symlink is never followed.
    let home = tempfile::tempdir().unwrap();
    let elsewhere = tempfile::NamedTempFile::new().unwrap();
    std::fs::write(elsewhere.path(), "stolen\n").unwrap();
    std::os::unix::fs::symlink(elsewhere.path(), home.path().join("token")).unwrap();
    let rt = tokio::runtime::Runtime::new().unwrap();
    let err = match rt.block_on(Daemon::start(opts(home.path()))) {
        Err(e) => e,
        Ok(_) => panic!("started with a symlinked token"),
    };
    assert!(err.to_string().contains("symlink"), "{err}");
    assert_eq!(std::fs::read_to_string(elsewhere.path()).unwrap(), "stolen\n");

    // So is daemon.json.
    let home = tempfile::tempdir().unwrap();
    std::os::unix::fs::symlink(elsewhere.path(), home.path().join("daemon.json")).unwrap();
    assert!(rt.block_on(Daemon::start(opts(home.path()))).is_err());
    assert_eq!(std::fs::read_to_string(elsewhere.path()).unwrap(), "stolen\n");
}

#[test]
fn a8_one_daemon_per_home_and_the_lock_is_released_on_shutdown_and_failed_start() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let home = tempfile::tempdir().unwrap();
    let first = rt.block_on(Daemon::start(opts(home.path()))).unwrap();
    let err = match rt.block_on(Daemon::start(opts(home.path()))) {
        Err(e) => e,
        Ok(_) => panic!("a second daemon started on the same home"),
    };
    assert_eq!(err.kind(), std::io::ErrorKind::AddrInUse);
    assert!(err.to_string().contains("already running"), "{err}");
    // The refused start left the first daemon's files alone and it still answers.
    let port: Value = serde_json::from_str(&std::fs::read_to_string(home.path().join("daemon.json")).unwrap()).unwrap();
    assert_eq!(port["port"], first.addr.port());

    // A start that fails on a busy port, with sync on, releases its lock and leaves no daemon.json.
    let other = tempfile::tempdir().unwrap();
    let busy = Options { port: first.addr.port(), sync: SyncMode::Local, ..Options::new(other.path().to_path_buf()) };
    assert!(rt.block_on(Daemon::start(busy)).is_err());
    assert!(!other.path().join("daemon.json").exists());
    let retry = rt.block_on(Daemon::start(opts(other.path()))).unwrap();
    rt.block_on(retry.shutdown()).unwrap();

    // Shutdown releases the lock.
    rt.block_on(first.shutdown()).unwrap();
    let again = rt.block_on(Daemon::start(opts(home.path()))).unwrap();
    rt.block_on(again.shutdown()).unwrap();
}

#[test]
fn a9_events_endpoint_pages_with_default_1000_and_max_10000() {
    // Prefill the store before the daemon opens it: 10 500 events of a peer Device.
    let home = tempfile::tempdir().unwrap();
    {
        let (mut store, _key) =
            pomo_sync::open_store(&home.path().join("pomo.db"), &home.path().join("meta").join("key")).unwrap();
        let events: Vec<pomo_core::Event> = (1..=10_500u64)
            .map(|i| pomo_core::Event {
                id: format!("00000000-0000-4000-8000-{i:012}"),
                device_id: "peer".into(),
                seq: i,
                hlc_ms: 1_700_000_000_000 + i as i64,
                hlc_counter: 0,
                ty: "x.unknown".into(),
                payload: json!({}),
                source: pomo_core::Source::User,
                command_key: None,
            })
            .collect();
        assert_eq!(store.ingest(&events).unwrap().inserted, 10_500);
    }
    let td = Td::in_home(home);
    let n = |q: &str| td.get(&format!("/v1/events{q}")).1["events"].as_array().unwrap().len();
    assert_eq!(n(""), 1000);
    assert_eq!(n("?limit=50"), 50);
    assert_eq!(n("?limit=999999999"), 10_000);
    assert_eq!(td.get("/v1/events?limit=0").0, 400);
    // The next page by advancing the vector; a vector entry beyond i64 is clamped, not wrapped.
    let after = urlenc(r#"{"peer":10000}"#);
    assert_eq!(n(&format!("?after={after}&limit=10000")), 500);
    let huge = urlenc(r#"{"peer":18446744073709551615}"#);
    assert_eq!(n(&format!("?after={huge}")), 0);
    // Events come back in total order within the page.
    let (_, page) = td.get("/v1/events?limit=5");
    let seqs: Vec<u64> = page["events"].as_array().unwrap().iter().map(|e| e["seq"].as_u64().unwrap()).collect();
    assert_eq!(seqs, [1, 2, 3, 4, 5]);
}

fn urlenc(s: &str) -> String {
    s.bytes()
        .map(|b| if b.is_ascii_alphanumeric() { (b as char).to_string() } else { format!("%{b:02X}") })
        .collect()
}
