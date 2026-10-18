use std::fmt;

/// Everything that can go wrong in the sync layer.
#[derive(Debug)]
pub enum Error {
    /// The peer is not paired (or is revoked) on this Device.
    NotPaired(String),
    /// The peer answered with `{"t":"reject","reason":...}`.
    Rejected(String),
    /// A `(device_id, seq)` conflict; nothing from that frame was stored.
    Conflict(String),
    /// `seq` gap in a frame; nothing from that Device in that frame was stored.
    Gap(String),
    /// Malformed or unexpected frame, oversized frame.
    Protocol(String),
    /// A pairing ticket that cannot be parsed.
    BadTicket(String),
    /// Timeout waiting for the peer.
    Timeout(&'static str),
    /// The connection or stream ended unexpectedly.
    Closed(String),
    /// Connecting, binding or other iroh failure.
    Net(String),
    /// Test hook dropped the connection.
    Fault,
    Store(pomo_core::Error),
    Io(std::io::Error),
}

pub type Result<T, E = Error> = std::result::Result<T, E>;

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::NotPaired(d) => write!(f, "device {d} is not paired"),
            Error::Rejected(r) => write!(f, "peer rejected the session: {r}"),
            Error::Conflict(m) => write!(f, "conflict: {m}"),
            Error::Gap(m) => write!(f, "seq gap: {m}"),
            Error::Protocol(m) => write!(f, "protocol error: {m}"),
            Error::BadTicket(m) => write!(f, "bad ticket: {m}"),
            Error::Timeout(what) => write!(f, "timeout waiting for {what}"),
            Error::Closed(m) => write!(f, "connection closed: {m}"),
            Error::Net(m) => write!(f, "network: {m}"),
            Error::Fault => write!(f, "injected fault"),
            Error::Store(e) => write!(f, "store: {e}"),
            Error::Io(e) => write!(f, "io: {e}"),
        }
    }
}

impl std::error::Error for Error {}

impl From<pomo_core::Error> for Error {
    fn from(e: pomo_core::Error) -> Self {
        Error::Store(e)
    }
}
impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e)
    }
}
impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Error::Protocol(format!("json: {e}"))
    }
}
