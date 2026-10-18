use crate::error::{Error, Result};
use crate::session;
use crate::wire::{read_frame, write_frame, Frame, ALPN, MAX_EVENTS_PER_FRAME};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use iroh::endpoint::{presets, Connection, RecvStream, SendStream};
use iroh::protocol::{AcceptError, ProtocolHandler, Router};
use iroh::{Endpoint, EndpointAddr, EndpointId, RelayMode, SecretKey};
use iroh_tickets::endpoint::EndpointTicket;
use pomo_core::{Command, Event, Source, Store};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::{broadcast, oneshot, watch};
use tokio::time::timeout;

pub const PAIR_PREFIX: &str = "pomo-pair:";

/// Which network the iroh endpoint uses.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Network {
    /// iroh's `N0` preset: default n0 relays and n0 address lookup.
    N0,
    /// Loopback only, relay and address lookup disabled. Peers are reached by the direct
    /// addresses inside tickets. For tests and same-machine use.
    Local,
}

#[derive(Clone, Debug)]
pub struct SyncOptions {
    pub network: Network,
    /// Start in live mode (see [`SyncNode::set_live`]).
    pub live: bool,
    /// Validity of pairing tickets. Spec: 5 minutes.
    pub ticket_ttl: Duration,
    /// Events per `events` frame (spec maximum 500).
    pub events_per_frame: usize,
    /// Live-mode ping period (spec: 20 s).
    pub ping_interval: Duration,
    /// Close a session after this long without any frame (spec: 60 s).
    pub idle_timeout: Duration,
    pub connect_timeout: Duration,
    /// Test hook: once, abruptly close the connection instead of sending event frame number
    /// `n + 1` of a session.
    pub drop_after_frames: Option<usize>,
    /// A session is aborted with an error once the peer has sent this many events in it. What
    /// was stored stays stored; the next session continues. Default 50 000.
    pub max_events_per_session: usize,
    /// Connections from Devices that are not (or no longer) trusted are served at most this
    /// many at a time, until they pair; the rest are dropped at once. Default 16.
    pub max_unauthenticated: usize,
}

impl Default for SyncOptions {
    fn default() -> Self {
        SyncOptions {
            network: Network::N0,
            live: false,
            ticket_ttl: Duration::from_secs(5 * 60),
            events_per_frame: MAX_EVENTS_PER_FRAME,
            ping_interval: Duration::from_secs(20),
            idle_timeout: Duration::from_secs(60),
            connect_timeout: Duration::from_secs(30),
            drop_after_frames: None,
            max_events_per_session: 50_000,
            max_unauthenticated: 16,
        }
    }
}

impl SyncOptions {
    pub fn local() -> Self {
        SyncOptions { network: Network::Local, ..Default::default() }
    }
}

/// Result of one session's exchange phase.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SyncReport {
    pub peer: String,
    /// Events sent to the peer.
    pub sent: usize,
    /// Events newly stored from the peer.
    pub received: usize,
    /// The session stays open in live mode after this report.
    pub live: bool,
}

/// Result of [`SyncNode::pair`].
#[derive(Clone, Debug)]
pub struct PairOutcome {
    pub device_id: String,
    pub name: String,
    pub sync: SyncReport,
}

#[derive(Serialize, Deserialize)]
struct TicketBody {
    ticket: String,
    secret: String,
    name: String,
}

struct Offer {
    expires_ms: i64,
    used: bool,
    name: String,
}

/// A pairing ticket as returned by [`SyncNode::pairing_ticket`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PairingTicket {
    /// `pomo-pair:<base64url json>`.
    pub ticket: String,
    pub expires_ms: i64,
}

/// What this Device thinks of a peer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Trust {
    Paired,
    Unpaired,
    Revoked,
}

pub(crate) struct Inner {
    pub store: Arc<Mutex<Store>>,
    pub device_id: String,
    pub endpoint: Endpoint,
    pub opts: SyncOptions,
    live: AtomicBool,
    /// Armed test hook, fires once.
    pub fault: Mutex<Option<usize>>,
    pub changed: watch::Sender<u64>,
    pub ingested: broadcast::Sender<Vec<Event>>,
    offers: Mutex<HashMap<String, Offer>>,
    sessions: Mutex<HashMap<u64, (String, Connection)>>,
    next_session: AtomicU64,
    /// Connections currently in the unauthenticated phase (see [`SyncOptions::max_unauthenticated`]).
    unauthenticated: AtomicUsize,
}

/// Counts one unauthenticated connection until dropped.
struct UnauthGuard<'a>(&'a AtomicUsize);

impl Drop for UnauthGuard<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

impl Inner {
    pub fn is_live(&self) -> bool {
        self.live.load(Ordering::SeqCst)
    }

    fn trust(&self, device_id: &str) -> Result<Trust> {
        Ok(match self.store.lock().unwrap().device(device_id)? {
            Some(d) if d.revoked => Trust::Revoked,
            Some(d) if d.paired => Trust::Paired,
            _ => Trust::Unpaired,
        })
    }

    /// Marks the device paired and clears a revocation: pairing is an explicit human act. The
    /// steps are ordered so that an interruption leaves the device untrusted, never trusted.
    fn set_paired(&self, device_id: &str, name: &str) -> Result<()> {
        let mut store = self.store.lock().unwrap();
        store.upsert_device(device_id, name)?;
        store.set_device_revoked(device_id, false)?;
        store.set_device_paired(device_id, true)?;
        Ok(())
    }

    fn set_revoked(&self, device_id: &str) -> Result<()> {
        let mut store = self.store.lock().unwrap();
        store.set_device_revoked(device_id, true)?;
        store.set_device_paired(device_id, false)?;
        Ok(())
    }

    /// Persists `addr` as the last known address of its endpoint.
    fn remember(&self, addr: &EndpointAddr) -> Result<()> {
        let ticket = EndpointTicket::new(addr.clone()).to_string();
        self.store.lock().unwrap().set_peer_address(&addr.id.to_string(), &ticket, now_ms())?;
        Ok(())
    }

    fn address_of(&self, id: &EndpointId) -> Result<Option<EndpointAddr>> {
        let Some(text) = self.store.lock().unwrap().peer_address(&id.to_string())? else { return Ok(None) };
        Ok(EndpointTicket::from_str(&text).ok().map(|t| t.endpoint_addr().clone()))
    }

    /// Wakes live sessions: new events may be stored.
    pub fn notify(&self) {
        self.changed.send_modify(|v| *v += 1);
    }

    fn register(&self, peer: &str, conn: &Connection) -> SessionGuard<'_> {
        let id = self.next_session.fetch_add(1, Ordering::SeqCst);
        self.sessions.lock().unwrap().insert(id, (peer.to_string(), conn.clone()));
        SessionGuard { inner: self, id }
    }

    fn check_offer(&self, secret: &str) -> std::result::Result<String, &'static str> {
        let now = now_ms();
        let mut offers = self.offers.lock().unwrap();
        offers.retain(|_, o| o.expires_ms + 3_600_000 > now);
        // Compare against every offer without early exit.
        let mut found: Option<String> = None;
        for key in offers.keys() {
            if ct_eq(key.as_bytes(), secret.as_bytes()) {
                found = Some(key.clone());
            }
        }
        let key = found.ok_or("bad_secret")?;
        let offer = offers.get_mut(&key).expect("key just found");
        if offer.used {
            return Err("used");
        }
        if now > offer.expires_ms {
            return Err("expired");
        }
        offer.used = true;
        Ok(offer.name.clone())
    }

    fn own_hello(&self) -> Result<Frame> {
        let vv = self.store.lock().unwrap().version_vector()?;
        Ok(Frame::Hello { device_id: self.device_id.clone(), vv, live: self.is_live() })
    }

    /// Listener side of one connection.
    async fn serve(self: &Arc<Self>, conn: Connection) -> Result<()> {
        let peer = conn.remote_id().to_string();
        // Anyone who knows the endpoint id can reach this point; only trusted Devices are
        // exempt from the cap on concurrent connections that have not authenticated yet.
        let mut unauth = if self.trust(&peer)? == Trust::Paired {
            None
        } else {
            let n = self.unauthenticated.fetch_add(1, Ordering::SeqCst);
            if n >= self.opts.max_unauthenticated {
                self.unauthenticated.fetch_sub(1, Ordering::SeqCst);
                conn.close(3u32.into(), b"busy");
                return Err(Error::Protocol("too many unauthenticated connections".into()));
            }
            Some(UnauthGuard(&self.unauthenticated))
        };
        let _guard = self.register(&peer, &conn);
        let (mut send, mut recv) = timeout(Duration::from_secs(10), conn.accept_bi())
            .await
            .map_err(|_| Error::Timeout("stream"))?
            .map_err(|e| Error::Closed(e.to_string()))?;
        let mut first = timeout(Duration::from_secs(10), read_frame(&mut recv))
            .await
            .map_err(|_| Error::Timeout("first frame"))??;
        if let Frame::Pair { secret, device_id, name } = first {
            if device_id != peer {
                return reject(&conn, &mut send, "bad_secret").await;
            }
            match self.check_offer(&secret) {
                Ok(own_name) => {
                    self.set_paired(&peer, &name)?;
                    drop(unauth.take());
                    write_frame(&mut send, &Frame::PairOk { device_id: self.device_id.clone(), name: own_name })
                        .await?;
                }
                Err(reason) => return reject(&conn, &mut send, reason).await,
            }
            first = timeout(Duration::from_secs(10), read_frame(&mut recv))
                .await
                .map_err(|_| Error::Timeout("hello"))??;
        }
        let Frame::Hello { device_id, vv, live: peer_live } = first else {
            return Err(Error::Protocol(format!("expected hello, got {first:?}")));
        };
        if device_id != peer {
            return reject(&conn, &mut send, "unpaired").await;
        }
        match self.trust(&peer)? {
            Trust::Paired => drop(unauth.take()),
            Trust::Unpaired => return reject(&conn, &mut send, "unpaired").await,
            Trust::Revoked => return reject(&conn, &mut send, "revoked").await,
        }
        write_frame(&mut send, &self.own_hello()?).await?;
        session::run(self, &conn, &mut send, &mut recv, &peer, vv, peer_live, None).await?;
        Ok(())
    }

    async fn connect(&self, addr: EndpointAddr) -> Result<(Connection, SendStream, RecvStream)> {
        let conn = timeout(self.opts.connect_timeout, self.endpoint.connect(addr, ALPN))
            .await
            .map_err(|_| Error::Timeout("connect"))?
            .map_err(|e| Error::Net(e.to_string()))?;
        let (send, recv) = conn.open_bi().await.map_err(|e| Error::Closed(e.to_string()))?;
        Ok((conn, send, recv))
    }

    /// Sends hello, reads the peer's reply and runs the session on a background task. Returns
    /// when the exchange is complete; non-live sessions are awaited to their end.
    async fn dialed_session(
        self: &Arc<Self>,
        conn: Connection,
        mut send: SendStream,
        mut recv: RecvStream,
        peer: String,
    ) -> Result<SyncReport> {
        write_frame(&mut send, &self.own_hello()?).await?;
        let reply = timeout(Duration::from_secs(10), read_frame(&mut recv))
            .await
            .map_err(|_| Error::Timeout("hello"))??;
        let (vv, peer_live) = match reply {
            Frame::Hello { device_id, vv, live } if device_id == peer => (vv, live),
            Frame::Reject { reason } => {
                conn.close(0u32.into(), b"rejected");
                return Err(Error::Rejected(reason));
            }
            other => return Err(Error::Protocol(format!("expected hello, got {other:?}"))),
        };
        let (tx, rx) = oneshot::channel();
        let inner = self.clone();
        let task = tokio::spawn(async move {
            let guard = inner.register(&peer, &conn);
            let res = session::run(&inner, &conn, &mut send, &mut recv, &peer, vv, peer_live, Some(tx)).await;
            drop(guard);
            if res.is_ok() {
                // Let the listener close first so our last frames are delivered. After a
                // failed session there is nothing left to deliver: close at once.
                let _ = timeout(Duration::from_secs(5), conn.closed()).await;
            }
            conn.close(if res.is_ok() { 0u32 } else { 1u32 }.into(), b"bye");
            res
        });
        match rx.await {
            Ok(report) if report.live => Ok(report),
            Ok(report) => {
                task.await.map_err(|e| Error::Closed(e.to_string()))??;
                Ok(report)
            }
            Err(_) => Err(task.await.map_err(|e| Error::Closed(e.to_string()))?.err().unwrap_or(Error::Closed(
                "session ended before exchange completed".into(),
            ))),
        }
    }
}

struct SessionGuard<'a> {
    inner: &'a Inner,
    id: u64,
}

impl Drop for SessionGuard<'_> {
    fn drop(&mut self) {
        self.inner.sessions.lock().unwrap().remove(&self.id);
    }
}

async fn reject(conn: &Connection, send: &mut SendStream, reason: &str) -> Result<()> {
    write_frame(send, &Frame::Reject { reason: reason.to_string() }).await?;
    let _ = send.finish();
    let _ = timeout(Duration::from_secs(5), conn.closed()).await;
    Err(Error::Rejected(reason.to_string()))
}

struct Handler(Arc<Inner>);

impl std::fmt::Debug for Handler {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("pomo-sync handler")
    }
}

impl ProtocolHandler for Handler {
    async fn accept(&self, conn: Connection) -> std::result::Result<(), AcceptError> {
        match self.0.serve(conn.clone()).await {
            Ok(()) => conn.close(0u32.into(), b"bye"),
            Err(e) => {
                tracing::debug!(error = %e, "inbound sync session ended");
                conn.close(1u32.into(), b"error");
            }
        }
        Ok(())
    }
}

/// An iroh endpoint serving `pomo/sync/1` over one store.
pub struct SyncNode {
    inner: Arc<Inner>,
    router: Router,
}

impl SyncNode {
    /// Opens (creating when absent) the key at `<db dir>/meta/key` and the store at `db_path`,
    /// then starts the node.
    pub async fn open(db_path: impl AsRef<Path>, opts: SyncOptions) -> Result<SyncNode> {
        let db_path = db_path.as_ref();
        let (store, key) = open_store(db_path, &default_key_path(db_path))?;
        SyncNode::start(Arc::new(Mutex::new(store)), key, opts).await
    }

    /// Starts a node over an open store. `store` must have been opened with
    /// `secret.public().to_string()` as its device id (see [`open_store`]).
    pub async fn start(store: Arc<Mutex<Store>>, secret: SecretKey, opts: SyncOptions) -> Result<SyncNode> {
        let device_id = secret.public().to_string();
        let stored = store.lock().unwrap().device_id().to_string();
        if stored != device_id {
            return Err(Error::Store(pomo_core::Error::DeviceMismatch { stored, requested: device_id }));
        }
        let builder = match opts.network {
            Network::N0 => Endpoint::builder(presets::N0),
            Network::Local => Endpoint::builder(presets::Minimal)
                .relay_mode(RelayMode::Disabled)
                .clear_ip_transports()
                .bind_addr("127.0.0.1:0")
                .map_err(|e| Error::Net(e.to_string()))?,
        };
        let endpoint = builder.secret_key(secret).bind().await.map_err(|e| Error::Net(e.to_string()))?;
        let (changed, _) = watch::channel(0);
        let (ingested, _) = broadcast::channel(256);
        let inner = Arc::new(Inner {
            store,
            device_id,
            endpoint: endpoint.clone(),
            live: AtomicBool::new(opts.live),
            fault: Mutex::new(opts.drop_after_frames),
            opts,
            changed,
            ingested,
            offers: Mutex::new(HashMap::new()),
            sessions: Mutex::new(HashMap::new()),
            next_session: AtomicU64::new(0),
            unauthenticated: AtomicUsize::new(0),
        });
        let router = Router::builder(endpoint).accept(ALPN, Handler(inner.clone())).spawn();
        Ok(SyncNode { inner, router })
    }

    /// The iroh endpoint id in string form; also the store's device id.
    pub fn device_id(&self) -> &str {
        &self.inner.device_id
    }

    pub fn store(&self) -> &Arc<Mutex<Store>> {
        &self.inner.store
    }

    /// Newly ingested events (from peers), one `Vec` per stored frame.
    pub fn subscribe(&self) -> broadcast::Receiver<Vec<Event>> {
        self.inner.ingested.subscribe()
    }

    /// Applies a Command to the store and forwards the new event to live peers.
    pub fn apply(&self, cmd: Command, source: Source, now_ms: i64) -> pomo_core::Result<Event> {
        let ev = self.inner.store.lock().unwrap().apply(cmd, source, now_ms)?;
        self.inner.notify();
        Ok(ev)
    }

    /// Tells live sessions that the store changed. Call after writing to the store directly.
    pub fn notify(&self) {
        self.inner.notify();
    }

    /// Live mode: the node asks peers to keep sessions open (the hello carries the flag) and
    /// forwards new events on them. A session stays open while either side is live; a side
    /// that is not live keeps it until the peer says `bye` or closes. When neither side is
    /// live, sessions end with `bye` after both `done`s. The peer's flag is as of its hello.
    pub fn set_live(&self, live: bool) {
        self.inner.live.store(live, Ordering::SeqCst);
        self.inner.notify();
    }

    pub fn is_live(&self) -> bool {
        self.inner.is_live()
    }

    /// An iroh endpoint ticket (address only, no pairing secret) accepted by [`Self::sync_with`].
    pub async fn endpoint_ticket(&self) -> String {
        self.wait_online().await;
        EndpointTicket::new(self.inner.endpoint.addr()).to_string()
    }

    async fn wait_online(&self) {
        if self.inner.opts.network == Network::N0 {
            let _ = timeout(Duration::from_secs(5), self.inner.endpoint.online()).await;
        }
    }

    /// Creates a pairing ticket `pomo-pair:<base64url(json {ticket, secret, name})>`, valid for
    /// `ticket_ttl` and one use. `name` is this Device's name as shown to the joiner.
    pub async fn pairing_ticket(&self, name: &str) -> Result<PairingTicket> {
        self.wait_online().await;
        let mut secret = [0u8; 16];
        rand::rngs::OsRng.fill_bytes(&mut secret);
        let secret = URL_SAFE_NO_PAD.encode(secret);
        let body = TicketBody {
            ticket: EndpointTicket::new(self.inner.endpoint.addr()).to_string(),
            secret: secret.clone(),
            name: name.to_string(),
        };
        let expires_ms = now_ms() + self.inner.opts.ticket_ttl.as_millis() as i64;
        self.inner.offers.lock().unwrap().insert(secret, Offer { expires_ms, used: false, name: name.to_string() });
        Ok(PairingTicket { ticket: format!("{PAIR_PREFIX}{}", URL_SAFE_NO_PAD.encode(serde_json::to_vec(&body)?)), expires_ms })
    }

    /// Joins the Device that offered `ticket`: pairing handshake, then a normal exchange.
    pub async fn pair(&self, ticket: &str, own_name: &str) -> Result<PairOutcome> {
        let body = ticket
            .trim()
            .strip_prefix(PAIR_PREFIX)
            .ok_or_else(|| Error::BadTicket("not a pairing ticket".into()))?;
        let raw = URL_SAFE_NO_PAD.decode(body).map_err(|e| Error::BadTicket(e.to_string()))?;
        let body: TicketBody = serde_json::from_slice(&raw).map_err(|e| Error::BadTicket(e.to_string()))?;
        let addr = EndpointTicket::from_str(&body.ticket)
            .map_err(|e| Error::BadTicket(e.to_string()))?
            .endpoint_addr()
            .clone();
        let peer = addr.id.to_string();
        let inner = &self.inner;
        inner.remember(&addr)?;
        let (conn, mut send, mut recv) = inner.connect(addr).await?;
        write_frame(
            &mut send,
            &Frame::Pair { secret: body.secret, device_id: inner.device_id.clone(), name: own_name.to_string() },
        )
        .await?;
        let reply = timeout(Duration::from_secs(10), read_frame(&mut recv))
            .await
            .map_err(|_| Error::Timeout("pair reply"))??;
        let name = match reply {
            Frame::PairOk { device_id, name } if device_id == peer => name,
            Frame::Reject { reason } => {
                conn.close(0u32.into(), b"rejected");
                return Err(Error::Rejected(reason));
            }
            other => return Err(Error::Protocol(format!("expected pair_ok, got {other:?}"))),
        };
        inner.set_paired(&peer, &name)?;
        let sync = inner.dialed_session(conn, send, recv, peer.clone()).await?;
        Ok(PairOutcome { device_id: peer, name, sync })
    }

    /// Runs one session with a paired Device. `target` is its device id (the address is the
    /// last one remembered from a ticket, persisted across restarts, or found by address
    /// lookup on [`Network::N0`]) or an endpoint ticket from [`Self::endpoint_ticket`].
    pub async fn sync_with(&self, target: &str) -> Result<SyncReport> {
        let target = target.trim();
        if target.starts_with(PAIR_PREFIX) {
            return Err(Error::BadTicket("pairing tickets are for pair()".into()));
        }
        let inner = &self.inner;
        let addr = match EndpointTicket::from_str(target) {
            Ok(t) => {
                let addr = t.endpoint_addr().clone();
                inner.remember(&addr)?;
                addr
            }
            Err(_) => {
                let id = EndpointId::from_str(target).map_err(|e| Error::Protocol(format!("target: {e}")))?;
                inner.address_of(&id)?.unwrap_or_else(|| EndpointAddr::new(id))
            }
        };
        let peer = addr.id.to_string();
        if inner.trust(&peer)? != Trust::Paired {
            return Err(Error::NotPaired(peer));
        }
        let (conn, send, recv) = inner.connect(addr).await?;
        inner.dialed_session(conn, send, recv, peer).await
    }

    /// Whether [`Self::sync_with`] has an address for `device_id`: a remembered one, or any on
    /// [`Network::N0`] where address lookup finds the endpoint.
    pub fn knows_address(&self, device_id: &str) -> bool {
        self.inner.opts.network == Network::N0
            || EndpointId::from_str(device_id)
                .ok()
                .is_some_and(|id| self.inner.address_of(&id).ok().flatten().is_some())
    }

    /// Whether a session (either direction) with `device_id` is open right now.
    pub fn has_session(&self, device_id: &str) -> bool {
        self.inner.sessions.lock().unwrap().values().any(|(peer, _)| peer == device_id)
    }

    /// Marks a Device as paired locally, without the handshake (the other side must trust this
    /// Device too before a session is accepted).
    pub fn trust_device(&self, device_id: &str, name: &str) -> Result<()> {
        self.inner.set_paired(device_id, name)
    }

    pub fn is_paired(&self, device_id: &str) -> Result<bool> {
        Ok(self.inner.trust(device_id)? == Trust::Paired)
    }

    /// Revokes a Device and closes its open sessions.
    pub fn revoke(&self, device_id: &str) -> Result<()> {
        self.inner.set_revoked(device_id)?;
        for (peer, conn) in self.inner.sessions.lock().unwrap().values() {
            if peer == device_id {
                conn.close(2u32.into(), b"revoked");
            }
        }
        Ok(())
    }

    /// Closes the endpoint and all sessions.
    pub async fn shutdown(&self) {
        let _ = self.router.shutdown().await;
    }
}

/// Default key location: `<db dir>/meta/key`.
pub fn default_key_path(db_path: &Path) -> PathBuf {
    db_path.parent().unwrap_or(Path::new(".")).join("meta").join("key")
}

/// Loads the secret key at `key_path` (creating it, mode 600, when absent), then opens the
/// store at `db_path` with the key's endpoint id as device id.
pub fn open_store(db_path: &Path, key_path: &Path) -> Result<(Store, SecretKey)> {
    let key = load_or_create_key(key_path)?;
    let store = Store::open(db_path, &key.public().to_string())?;
    Ok((store, key))
}

fn load_or_create_key(path: &Path) -> Result<SecretKey> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    match std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(path) {
        Ok(mut f) => {
            let key = SecretKey::generate();
            writeln!(f, "{}", key.to_bytes().iter().map(|b| format!("{b:02x}")).collect::<String>())?;
            f.sync_all()?;
            Ok(key)
        }
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            let text = std::fs::read_to_string(path)?;
            SecretKey::from_str(text.trim()).map_err(|e| Error::Protocol(format!("key file {}: {e}", path.display())))
        }
        Err(e) => Err(e.into()),
    }
}
