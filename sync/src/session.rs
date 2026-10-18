//! One sync session after the hello exchange: concurrent reader and writer on one stream.

use crate::error::{Error, Result};
use crate::node::{Inner, SyncReport};
use crate::wire::{read_frame, write_events, write_frame, Frame};
use iroh::endpoint::{Connection, RecvStream, SendStream};
use pomo_core::{sort_events, Event, VersionVector};
use std::collections::BTreeMap;
use std::pin::pin;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::{oneshot, watch};
use tokio::time::{interval_at, timeout, Instant};

struct Shared {
    peer_vv: Mutex<VersionVector>,
    sent: AtomicUsize,
    received: AtomicUsize,
    recv_done: watch::Sender<bool>,
    reader_end: watch::Sender<bool>,
}

/// Resolves once the flag is true; the `Ref` guard never lives across a caller's await.
async fn wait_true(rx: &mut watch::Receiver<bool>) -> bool {
    rx.wait_for(|v| *v).await.is_ok()
}

fn advance(vv: &mut VersionVector, events: &[Event]) {
    for e in events {
        let slot = vv.entry(e.device_id.clone()).or_insert(0);
        *slot = (*slot).max(e.seq);
    }
}

/// Runs the exchange and, while the stream stays open, live mode. The stream stays open when
/// either side is live (`peer_live` is the flag from the peer's hello); a side that is not live
/// keeps it until the peer sends `bye` or closes. `report_tx` fires once both `done` frames
/// have crossed.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn run(
    inner: &Arc<Inner>,
    conn: &Connection,
    send: &mut SendStream,
    recv: &mut RecvStream,
    peer: &str,
    peer_vv: VersionVector,
    peer_live: bool,
    report_tx: Option<oneshot::Sender<SyncReport>>,
) -> Result<SyncReport> {
    let shared = Shared {
        peer_vv: Mutex::new(peer_vv),
        sent: AtomicUsize::new(0),
        received: AtomicUsize::new(0),
        recv_done: watch::channel(false).0,
        reader_end: watch::channel(false).0,
    };
    // Subscribe before the first send so a change during the initial exchange is not lost.
    let mut changed = inner.changed.subscribe();
    let mut recv_done_rx = shared.recv_done.subscribe();
    let mut reader_end_rx = shared.reader_end.subscribe();
    let mut report_tx = report_tx;
    let final_report: Mutex<Option<SyncReport>> = Mutex::new(None);

    let writer = async {
        let mut frames = 0usize;
        send_missing(inner, conn, send, &shared, &mut frames).await?;
        write_frame(send, &Frame::Done).await?;
        tokio::select! {
            biased;
            ok = wait_true(&mut recv_done_rx) => { if !ok { return Err(Error::Closed("reader gone".into())); } }
            _ = wait_true(&mut reader_end_rx) => {
                if !*shared.recv_done.borrow() {
                    return Err(Error::Closed("peer ended before done".into()));
                }
            }
        }
        let report = SyncReport {
            peer: peer.to_string(),
            sent: shared.sent.load(Ordering::SeqCst),
            received: shared.received.load(Ordering::SeqCst),
            live: inner.is_live() || peer_live,
        };
        *final_report.lock().unwrap() = Some(report.clone());
        if let Some(tx) = report_tx.take() {
            let _ = tx.send(report);
        }
        let ping = inner.opts.ping_interval;
        let mut ticker = interval_at(Instant::now() + ping, ping);
        let mut was_live = inner.is_live();
        loop {
            if *reader_end_rx.borrow() {
                return Ok(());
            }
            let live = inner.is_live();
            // Neither side wants the stream, or this side just stopped being live: say bye.
            // A side that was never live keeps a stream the peer asked for until the peer ends it.
            if !live && (!peer_live || was_live) {
                let _ = write_frame(send, &Frame::Bye).await;
                let _ = send.finish();
                return Ok(());
            }
            was_live = live;
            // Pings keep both sides' idle timers fresh, also on a side that only listens.
            tokio::select! {
                _ = changed.changed() => send_missing(inner, conn, send, &shared, &mut frames).await?,
                _ = ticker.tick() => write_frame(send, &Frame::Ping).await?,
                _ = wait_true(&mut reader_end_rx) => return Ok(()),
            }
        }
    };

    let reader = async {
        let result = read_loop(inner, recv, peer, &shared).await;
        shared.reader_end.send_replace(true);
        result
    };

    let mut writer = pin!(writer);
    let mut reader = pin!(reader);
    let (mut w_done, mut r_done) = (false, false);
    while !(w_done && r_done) {
        tokio::select! {
            r = &mut reader, if !r_done => { r?; r_done = true; }
            w = &mut writer, if !w_done => { w?; w_done = true; }
        }
    }
    let report = final_report.lock().unwrap().clone();
    report.ok_or_else(|| Error::Closed("session ended before exchange completed".into()))
}

async fn send_missing(
    inner: &Arc<Inner>,
    conn: &Connection,
    send: &mut SendStream,
    shared: &Shared,
    frames: &mut usize,
) -> Result<()> {
    let mut events = {
        let vv = shared.peer_vv.lock().unwrap().clone();
        inner.store.lock().unwrap().events_after(&vv)?
    };
    sort_events(&mut events);
    let per_frame = inner.opts.events_per_frame;
    for chunk in events.chunks(per_frame.max(1)) {
        let fire = {
            let mut fault = inner.fault.lock().unwrap();
            let fire = fault.is_some_and(|n| *frames >= n);
            if fire {
                *fault = None;
            }
            fire
        };
        if fire {
            // Let the peer read the frames already sent; closing discards unread data.
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
            conn.close(7u32.into(), b"fault");
            return Err(Error::Fault);
        }
        *frames += write_events(send, chunk, per_frame).await?;
        advance(&mut shared.peer_vv.lock().unwrap(), chunk);
        shared.sent.fetch_add(chunk.len(), Ordering::SeqCst);
    }
    Ok(())
}

async fn read_loop(inner: &Arc<Inner>, recv: &mut RecvStream, peer: &str, shared: &Shared) -> Result<()> {
    loop {
        let frame = match timeout(inner.opts.idle_timeout, read_frame(recv)).await {
            Err(_) => return Err(Error::Timeout("a frame")),
            Ok(Ok(f)) => f,
            Ok(Err(Error::Closed(m))) => {
                return if *shared.recv_done.borrow() { Ok(()) } else { Err(Error::Closed(m)) };
            }
            Ok(Err(e)) => return Err(e),
        };
        match frame {
            Frame::Events { events } => {
                let n = ingest_frame(inner, peer, events, shared)?;
                shared.received.fetch_add(n, Ordering::SeqCst);
            }
            Frame::Done => {
                shared.recv_done.send_replace(true);
            }
            Frame::Ping => {}
            Frame::Bye => {
                return if *shared.recv_done.borrow() {
                    Ok(())
                } else {
                    Err(Error::Protocol("bye before done".into()))
                };
            }
            Frame::Reject { reason } => return Err(Error::Rejected(reason)),
            other => return Err(Error::Protocol(format!("unexpected frame {other:?}"))),
        }
    }
}

/// Validates and stores one `events` frame. Returns the number of newly stored events.
fn ingest_frame(inner: &Arc<Inner>, peer: &str, events: Vec<Event>, shared: &Shared) -> Result<usize> {
    let mut store = inner.store.lock().unwrap();
    let vv = store.version_vector()?;
    // Per Device: the unseen seqs must continue the stored run without holes.
    let mut unseen: BTreeMap<&str, Vec<u64>> = BTreeMap::new();
    for e in &events {
        if e.device_id == inner.device_id && e.seq > vv.get(&e.device_id).copied().unwrap_or(0) {
            return Err(Error::Protocol(format!("peer sent events of this Device we never issued ({})", e.seq)));
        }
        if e.seq > vv.get(&e.device_id).copied().unwrap_or(0) {
            unseen.entry(&e.device_id).or_default().push(e.seq);
        }
    }
    let mut gapped: Vec<String> = Vec::new();
    for (dev, seqs) in &mut unseen {
        seqs.sort_unstable();
        seqs.dedup();
        let base = vv.get(*dev).copied().unwrap_or(0);
        let contiguous = seqs.iter().enumerate().all(|(i, s)| *s == base + 1 + i as u64);
        if !contiguous {
            gapped.push((*dev).to_string());
        }
    }
    let keep: Vec<Event> = events.iter().filter(|e| !gapped.contains(&e.device_id)).cloned().collect();
    let report = match store.ingest_atomic(&keep) {
        Ok(r) => r,
        Err(pomo_core::Error::Conflict(m)) => {
            tracing::warn!(peer, %m, "sync session aborted: conflict");
            return Err(Error::Conflict(m));
        }
        Err(e) => return Err(e.into()),
    };
    if !report.invalid.is_empty() {
        tracing::warn!(peer, invalid = report.invalid.len(), "peer sent invalid events");
    }
    let after = store.version_vector()?;
    drop(store);
    advance(&mut shared.peer_vv.lock().unwrap(), &keep);
    let new: Vec<Event> = keep
        .into_iter()
        .filter(|e| {
            e.seq > vv.get(&e.device_id).copied().unwrap_or(0)
                && e.seq <= after.get(&e.device_id).copied().unwrap_or(0)
        })
        .collect();
    let n = new.len();
    if n > 0 {
        let _ = inner.ingested.send(new);
        inner.notify();
    }
    if let Some(dev) = gapped.first() {
        return Err(Error::Gap(format!("events of {dev} do not continue from the stored run")));
    }
    Ok(n)
}
