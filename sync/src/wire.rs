//! Frames of `pomo/sync/1`: 4-byte big-endian length, then a UTF-8 JSON object with a `t` field.

use crate::error::{Error, Result};
use pomo_core::{Event, VersionVector};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub const ALPN: &[u8] = b"pomo/sync/1";
/// Maximum frame body (4 MiB).
pub const MAX_FRAME: usize = 4 * 1024 * 1024;
/// Maximum events per `events` frame.
pub const MAX_EVENTS_PER_FRAME: usize = 500;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum Frame {
    Pair { secret: String, device_id: String, name: String },
    PairOk { device_id: String, name: String },
    Reject { reason: String },
    Hello {
        device_id: String,
        vv: VersionVector,
        /// The sender keeps the stream open (Daemon or foreground app). Absent means false.
        #[serde(default)]
        live: bool,
    },
    Events { events: Vec<Event> },
    Done,
    Ping,
    Bye,
}

pub async fn write_frame<W: AsyncWrite + Unpin>(w: &mut W, frame: &Frame) -> Result<()> {
    let body = serde_json::to_vec(frame)?;
    write_raw(w, &body).await
}

async fn write_raw<W: AsyncWrite + Unpin>(w: &mut W, body: &[u8]) -> Result<()> {
    if body.len() > MAX_FRAME {
        return Err(Error::Protocol(format!("frame of {} bytes exceeds the maximum", body.len())));
    }
    let mut buf = Vec::with_capacity(4 + body.len());
    buf.extend_from_slice(&(body.len() as u32).to_be_bytes());
    buf.extend_from_slice(body);
    w.write_all(&buf).await.map_err(|e| Error::Closed(e.to_string()))
}

/// Sends `events` as `events` frames of at most `per_frame` events, splitting further when a
/// frame would exceed [`MAX_FRAME`]. Returns the number of frames written.
pub async fn write_events<W: AsyncWrite + Unpin>(
    w: &mut W,
    events: &[Event],
    per_frame: usize,
) -> Result<usize> {
    let mut frames = 0;
    for chunk in events.chunks(per_frame.clamp(1, MAX_EVENTS_PER_FRAME)) {
        frames += write_chunk(w, chunk).await?;
    }
    Ok(frames)
}

async fn write_chunk<W: AsyncWrite + Unpin>(w: &mut W, chunk: &[Event]) -> Result<usize> {
    let body = serde_json::to_vec(&Frame::Events { events: chunk.to_vec() })?;
    if body.len() <= MAX_FRAME {
        write_raw(w, &body).await?;
        return Ok(1);
    }
    if chunk.len() == 1 {
        return Err(Error::Protocol("single event larger than the maximum frame".into()));
    }
    let (a, b) = chunk.split_at(chunk.len() / 2);
    Ok(Box::pin(write_chunk(w, a)).await? + Box::pin(write_chunk(w, b)).await?)
}

pub async fn read_frame<R: AsyncRead + Unpin>(r: &mut R) -> Result<Frame> {
    let mut len = [0u8; 4];
    r.read_exact(&mut len).await.map_err(|e| Error::Closed(e.to_string()))?;
    let len = u32::from_be_bytes(len) as usize;
    if len > MAX_FRAME {
        return Err(Error::Protocol(format!("frame of {len} bytes exceeds the maximum")));
    }
    let mut body = vec![0u8; len];
    r.read_exact(&mut body).await.map_err(|e| Error::Closed(e.to_string()))?;
    Ok(serde_json::from_slice(&body)?)
}
