//! Pomo Daemon: serves spec/api.md over HTTP on 127.0.0.1.

use std::collections::{BTreeMap, HashMap};
use std::convert::Infallible;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::body::Bytes;
use axum::extract::{Query, Request, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::middleware::{self, Next};
use axum::response::sse::{self, KeepAlive, Sse};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::Engine;
use pomo_core::{
    sort_events, Block, Command, CommandBody, Error as CoreError, Kind, Outcome, Phase, Range,
    Source, Store, TimerStatus, VersionVector,
};
use rand::RngCore;
use serde_json::{json, Value};
use subtle::ConstantTimeEq;
use tokio::sync::{broadcast, watch};
use tokio::task::JoinHandle;
use tokio_stream::wrappers::BroadcastStream;
use futures_util::{Stream, StreamExt};

pub const DEFAULT_PORT: u16 = 47831;
const DAY_MS: i64 = 86_400_000;

/// Default data directory: `$POMO_HOME` or `~/.pomo`.
pub fn default_home() -> PathBuf {
    if let Some(h) = std::env::var_os("POMO_HOME") {
        return PathBuf::from(h);
    }
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
    home.join(".pomo")
}

pub struct Options {
    pub home: PathBuf,
    /// 0 picks a free port.
    pub port: u16,
}

/// A running daemon. Dropping it without [`Daemon::shutdown`] leaves `daemon.json` behind.
pub struct Daemon {
    pub addr: SocketAddr,
    pub token: String,
    pub home: PathBuf,
    shutdown: watch::Sender<bool>,
    task: JoinHandle<std::io::Result<()>>,
}

impl Daemon {
    pub async fn start(opts: Options) -> std::io::Result<Daemon> {
        std::fs::create_dir_all(&opts.home)?;
        let token = load_or_create_token(&opts.home)?;
        let device_id = load_or_create_device_id(&opts.home)?;
        let store = Store::open(opts.home.join("pomo.db"), &device_id)
            .map_err(|e| std::io::Error::other(e.to_string()))?;

        let listener = tokio::net::TcpListener::bind(("127.0.0.1", opts.port)).await?;
        let addr = listener.local_addr()?;

        let (tx, _) = broadcast::channel(256);
        let (sd_tx, sd_rx) = watch::channel(false);
        let shared = Arc::new(Shared {
            store: Mutex::new(store),
            token: token.clone(),
            tx,
            timer_task: Mutex::new(None),
            rt: tokio::runtime::Handle::current(),
            shutdown: sd_rx.clone(),
        });
        {
            let store = shared.lock_store();
            shared.reschedule(&store, now_ms());
        }

        let app = router(shared.clone());
        let daemon_json = opts.home.join("daemon.json");
        std::fs::write(&daemon_json, json!({"port": addr.port(), "pid": std::process::id()}).to_string())?;

        let mut sd = sd_rx;
        let task = tokio::spawn(async move {
            let res = axum::serve(listener, app)
                .with_graceful_shutdown(async move {
                    let _ = sd.wait_for(|v| *v).await;
                })
                .await;
            if let Some(h) = shared.timer_task.lock().unwrap_or_else(|e| e.into_inner()).take() {
                h.abort();
            }
            let _ = std::fs::remove_file(&daemon_json);
            res
        });
        Ok(Daemon { addr, token, home: opts.home, shutdown: sd_tx, task })
    }

    /// Stops serving, ends SSE streams and removes `daemon.json`.
    pub async fn shutdown(self) -> std::io::Result<()> {
        let _ = self.shutdown.send(true);
        self.task.await.map_err(std::io::Error::other)?
    }
}

fn load_or_create_token(home: &Path) -> std::io::Result<String> {
    let path = home.join("token");
    match std::fs::read_to_string(&path) {
        Ok(t) if !t.trim().is_empty() => return Ok(t.trim().to_string()),
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    let mut bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    let token = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes);
    write_private(&path, &token)?;
    Ok(token)
}

fn write_private(path: &Path, content: &str) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    let mut f = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(path)?;
    f.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    f.write_all(content.as_bytes())
}

fn random_hex() -> String {
    let mut b = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut b);
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn load_or_create_device_id(home: &Path) -> std::io::Result<String> {
    let path = home.join("device_id");
    match std::fs::read_to_string(&path) {
        Ok(t) if !t.trim().is_empty() => return Ok(t.trim().to_string()),
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    let id = random_hex();
    std::fs::write(&path, &id)?;
    Ok(id)
}

fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

fn local_offset_min() -> i32 {
    chrono::Local::now().offset().local_minus_utc() / 60
}

#[derive(Clone)]
struct Msg {
    name: &'static str,
    data: String,
}

struct Shared {
    store: Mutex<Store>,
    token: String,
    tx: broadcast::Sender<Msg>,
    timer_task: Mutex<Option<JoinHandle<()>>>,
    rt: tokio::runtime::Handle,
    shutdown: watch::Receiver<bool>,
}

impl Shared {
    fn lock_store(&self) -> MutexGuard<'_, Store> {
        self.store.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Replaces the pending `pomo.block_end` timer. Call after every command, with the store locked.
    fn reschedule(&self, store: &Store, now: i64) {
        let mut slot = self.timer_task.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(h) = slot.take() {
            h.abort();
        }
        let t = store.timer(now);
        if t.status != TimerStatus::Running {
            return;
        }
        if let (Some(block_id), Some(rem)) = (t.block_id, t.remaining_ms) {
            let ends_ms = now + rem;
            let tx = self.tx.clone();
            *slot = Some(self.rt.spawn(async move {
                tokio::time::sleep(Duration::from_millis(rem.max(0) as u64)).await;
                let data = json!({"block_id": block_id, "outcome": "completed", "ended_ms": ends_ms});
                let _ = tx.send(Msg { name: "pomo.block_end", data: data.to_string() });
            }));
        }
    }
}

struct ApiError {
    status: StatusCode,
    code: &'static str,
    message: String,
}

impl ApiError {
    fn new(status: StatusCode, code: &'static str, message: impl Into<String>) -> Self {
        ApiError { status, code, message: message.into() }
    }
    fn bad(message: impl Into<String>) -> Self {
        Self::new(StatusCode::BAD_REQUEST, "bad_request", message)
    }
}

impl From<CoreError> for ApiError {
    fn from(e: CoreError) -> Self {
        match e {
            CoreError::Invalid(m) if m.starts_with("unknown block") => {
                ApiError::new(StatusCode::NOT_FOUND, "not_found", m)
            }
            CoreError::Invalid(m) => ApiError::new(StatusCode::CONFLICT, "invalid_state", m),
            other => ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "internal", other.to_string()),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.status, Json(json!({"error": {"code": self.code, "message": self.message}}))).into_response()
    }
}

type ApiResult = Result<Json<Value>, ApiError>;

async fn blocking<T: Send + 'static>(
    sh: &Arc<Shared>,
    f: impl FnOnce(&Shared) -> Result<T, ApiError> + Send + 'static,
) -> Result<T, ApiError> {
    let sh = sh.clone();
    tokio::task::spawn_blocking(move || f(&sh))
        .await
        .map_err(|e| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "internal", e.to_string()))?
}

fn router(shared: Arc<Shared>) -> Router {
    Router::new()
        .route("/v1/status", get(status))
        .route("/v1/commands", post(commands))
        .route("/v1/blocks", get(blocks))
        .route("/v1/stats", get(stats))
        .route("/v1/events", get(events))
        .route("/v1/stream", get(stream))
        .fallback(|| async { ApiError::new(StatusCode::NOT_FOUND, "not_found", "no such endpoint") })
        .layer(middleware::from_fn_with_state(shared.clone(), auth))
        .with_state(shared)
}

async fn auth(State(sh): State<Arc<Shared>>, req: Request, next: Next) -> Response {
    let ok = req
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(|t| bool::from(t.as_bytes().ct_eq(sh.token.as_bytes())))
        .unwrap_or(false);
    if ok {
        next.run(req).await
    } else {
        let mut r = ApiError::new(StatusCode::UNAUTHORIZED, "unauthorized", "missing or invalid bearer token")
            .into_response();
        r.headers_mut().insert(header::WWW_AUTHENTICATE, "Bearer".parse().unwrap());
        r
    }
}

// ---------- JSON shapes ----------

fn block_json(b: &Block, now: i64) -> Value {
    let elapsed = if b.phase == Phase::Running {
        b.elapsed_ms + (now - b.phase_since_ms).max(0)
    } else {
        b.elapsed_ms
    };
    json!({
        "id": b.id,
        "kind": b.kind.as_str(),
        "label": b.label,
        "project": b.project,
        "source": b.source.to_string(),
        "device_id": b.device_id,
        "started_ms": b.started_ms,
        "planned_ms": b.planned_ms,
        "elapsed_ms": elapsed,
        "phase": b.phase.as_str(),
        "outcome": b.outcome.map(Outcome::as_str),
        "ended_ms": b.ended_ms,
    })
}

fn timer_json(store: &Store, now: i64) -> Result<Value, ApiError> {
    let t = store.timer(now);
    let block = match &t.block_id {
        Some(id) => store
            .blocks(Range::ALL, now)?
            .into_iter()
            .find(|b| &b.id == id)
            .map(|b| block_json(&b, now)),
        None => None,
    };
    Ok(json!({
        "status": serde_json::to_value(t.status).unwrap_or(Value::Null),
        "block": block,
        "remaining_ms": t.remaining_ms,
        "next_kind": t.next_kind.as_str(),
    }))
}

fn int_param(q: &HashMap<String, String>, key: &str) -> Result<Option<i64>, ApiError> {
    match q.get(key) {
        None => Ok(None),
        Some(v) => v.parse::<i64>().map(Some).map_err(|_| ApiError::bad(format!("{key} must be an integer"))),
    }
}

fn tz_param(q: &HashMap<String, String>) -> Result<i32, ApiError> {
    match int_param(q, "tz_offset_min")? {
        None => Ok(local_offset_min()),
        Some(v) if (-1440..=1440).contains(&v) => Ok(v as i32),
        Some(_) => Err(ApiError::bad("tz_offset_min out of range")),
    }
}

// ---------- handlers ----------

async fn status(State(sh): State<Arc<Shared>>, Query(q): Query<HashMap<String, String>>) -> ApiResult {
    let tz = tz_param(&q)?;
    blocking(&sh, move |sh| {
        let now = now_ms();
        let store = sh.lock_store();
        let start = (now + i64::from(tz) * 60_000).div_euclid(DAY_MS) * DAY_MS - i64::from(tz) * 60_000;
        let s = store.stats(Range { from_ms: start, to_ms: start + DAY_MS }, tz, now)?;
        Ok(Json(json!({
            "now_ms": now,
            "timer": timer_json(&store, now)?,
            "today": {"focus_ms": s.focus_ms_total, "completed_focus": s.completed_focus},
        })))
    })
    .await
}

fn parse_source(headers: &HeaderMap) -> Result<Source, ApiError> {
    let Some(v) = headers.get("x-pomo-source") else { return Ok(Source::User) };
    let v = v.to_str().map_err(|_| ApiError::bad("invalid X-Pomo-Source"))?;
    if v == "user" {
        return Ok(Source::User);
    }
    match v.strip_prefix("agent:") {
        Some(n)
            if (1..=32).contains(&n.len())
                && n.bytes().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_' || c == b'-') =>
        {
            Ok(Source::Agent(n.to_string()))
        }
        _ => Err(ApiError::bad("X-Pomo-Source must be `user` or `agent:<name>` with name [a-z0-9_-]{1,32}")),
    }
}

async fn commands(State(sh): State<Arc<Shared>>, headers: HeaderMap, body: Bytes) -> ApiResult {
    let source = parse_source(&headers)?;
    let mut cmd: Command =
        serde_json::from_slice(&body).map_err(|e| ApiError::bad(format!("invalid command: {e}")))?;
    match &cmd.body {
        CommandBody::Start { planned_ms, .. } if *planned_ms <= 0 => {
            return Err(ApiError::bad("planned_ms must be > 0"))
        }
        CommandBody::Extend { add_ms } if *add_ms <= 0 => return Err(ApiError::bad("add_ms must be > 0")),
        _ => {}
    }
    let key = match headers.get("idempotency-key") {
        Some(v) => v.to_str().map_err(|_| ApiError::bad("invalid Idempotency-Key"))?.to_string(),
        None => cmd.command_key.take().unwrap_or_else(random_hex),
    };
    if key.is_empty() {
        return Err(ApiError::bad("Idempotency-Key must not be empty"));
    }
    cmd.command_key = Some(key);
    blocking(&sh, move |sh| {
        let now = now_ms();
        let mut store = sh.lock_store();
        let before: VersionVector = store.version_vector()?;
        let event = store.apply(cmd, source, now)?;
        let replayed = before.get(&event.device_id).is_some_and(|max| event.seq <= *max);
        let event_json = serde_json::to_value(&event).map_err(CoreError::from)?;
        if !replayed {
            let _ = sh.tx.send(Msg { name: "pomo.event", data: event_json.to_string() });
        }
        sh.reschedule(&store, now);
        Ok(Json(json!({"event": event_json, "timer": timer_json(&store, now)?, "replayed": replayed})))
    })
    .await
}

async fn blocks(State(sh): State<Arc<Shared>>, Query(q): Query<HashMap<String, String>>) -> ApiResult {
    let range = Range {
        from_ms: int_param(&q, "from_ms")?.unwrap_or(i64::MIN),
        to_ms: int_param(&q, "to_ms")?.unwrap_or(i64::MAX),
    };
    let kind = match q.get("kind") {
        None => None,
        Some(k) => Some(Kind::parse(k).ok_or_else(|| ApiError::bad("kind must be focus, short_break or long_break"))?),
    };
    let limit = match int_param(&q, "limit")? {
        None => 100,
        Some(l) if l >= 1 => l.min(1000) as usize,
        Some(_) => return Err(ApiError::bad("limit must be >= 1")),
    };
    blocking(&sh, move |sh| {
        let now = now_ms();
        let mut all = sh.lock_store().blocks(range, now)?;
        all.retain(|b| kind.is_none_or(|k| b.kind == k));
        all.sort_by(|a, b| (b.started_ms, &b.id).cmp(&(a.started_ms, &a.id)));
        let out: Vec<Value> = all.iter().take(limit).map(|b| block_json(b, now)).collect();
        Ok(Json(json!({"blocks": out})))
    })
    .await
}

fn civil_day(ms: i64, tz_min: i32) -> String {
    let days = (ms + i64::from(tz_min) * 60_000).div_euclid(DAY_MS);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}")
}

#[derive(Clone, Copy)]
enum GroupBy {
    Day,
    Label,
    Project,
}

async fn stats(State(sh): State<Arc<Shared>>, Query(q): Query<HashMap<String, String>>) -> ApiResult {
    let range = Range {
        from_ms: int_param(&q, "from_ms")?.unwrap_or(0),
        to_ms: int_param(&q, "to_ms")?.unwrap_or(i64::MAX),
    };
    let tz = tz_param(&q)?;
    let group_by = match q.get("group_by").map(String::as_str) {
        None | Some("day") => GroupBy::Day,
        Some("label") => GroupBy::Label,
        Some("project") => GroupBy::Project,
        Some(_) => return Err(ApiError::bad("group_by must be day, label or project")),
    };
    blocking(&sh, move |sh| {
        let now = now_ms();
        let store = sh.lock_store();
        let s = store.stats(range, tz, now)?;
        let mut groups: BTreeMap<String, (i64, u64)> = BTreeMap::new();
        for b in store.blocks(range, now)?.iter().filter(|b| b.kind == Kind::Focus) {
            let key = match group_by {
                GroupBy::Day => civil_day(b.started_ms, tz),
                GroupBy::Label => b.label.clone().unwrap_or_default(),
                GroupBy::Project => b.project.clone().unwrap_or_default(),
            };
            let g = groups.entry(key).or_default();
            g.0 += b.elapsed_ms;
            g.1 += u64::from(b.outcome == Some(Outcome::Completed));
        }
        let mut groups: Vec<(String, (i64, u64))> = groups.into_iter().collect();
        if !matches!(group_by, GroupBy::Day) {
            groups.sort_by(|a, b| b.1 .0.cmp(&a.1 .0).then_with(|| a.0.cmp(&b.0)));
        }
        let groups: Vec<Value> = groups
            .into_iter()
            .map(|(k, (ms, n))| json!({"key": k, "focus_ms": ms, "completed_focus": n}))
            .collect();
        Ok(Json(json!({
            "from_ms": range.from_ms,
            "to_ms": range.to_ms,
            "tz_offset_min": tz,
            "focus_ms": s.focus_ms_total,
            "completed_focus": s.completed_focus,
            "streak_days": s.streak_days,
            "groups": groups,
        })))
    })
    .await
}

async fn events(State(sh): State<Arc<Shared>>, Query(q): Query<HashMap<String, String>>) -> ApiResult {
    let vv: VersionVector = match q.get("after") {
        None => VersionVector::new(),
        Some(s) => serde_json::from_str(s).map_err(|e| ApiError::bad(format!("after must be a JSON version vector: {e}")))?,
    };
    let limit = match int_param(&q, "limit")? {
        None => usize::MAX,
        Some(l) if l >= 1 => l as usize,
        Some(_) => return Err(ApiError::bad("limit must be >= 1")),
    };
    blocking(&sh, move |sh| {
        let mut evs = sh.lock_store().events_after(&vv)?;
        sort_events(&mut evs);
        evs.truncate(limit);
        Ok(Json(json!({"events": evs})))
    })
    .await
}

async fn stream(State(sh): State<Arc<Shared>>) -> Sse<impl Stream<Item = Result<sse::Event, Infallible>>> {
    let rx = sh.tx.subscribe();
    let mut sd = sh.shutdown.clone();
    let s = BroadcastStream::new(rx)
        .filter_map(|m| async move { m.ok() })
        .map(|m| Ok(sse::Event::default().event(m.name).data(m.data)))
        .take_until(Box::pin(async move {
            let _ = sd.wait_for(|v| *v).await;
        }));
    Sse::new(s).keep_alive(KeepAlive::new().interval(Duration::from_secs(15)).text("keepalive"))
}
