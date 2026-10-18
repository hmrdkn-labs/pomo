//! Regression tests for the review findings that touch Sync: per-Device seq order (A6), holes
//! from invalid events (A5), far-future clocks (R3-2), per-session and unauthenticated caps
//! (R3-4, R3-6).

mod common;
use common::*;
use iroh::endpoint::{presets, Connection};
use iroh::{Endpoint, RelayMode, SecretKey};
use iroh_tickets::endpoint::EndpointTicket;
use pomo_core::*;
use pomo_sync::wire::{read_frame, write_frame, Frame, ALPN};
use pomo_sync::SyncOptions;
use serde_json::json;
use std::str::FromStr;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;
use std::time::Duration;

const DAY: i64 = 86_400_000;

fn plain(id: u32, dev: &str, seq: u64, hlc: i64) -> Event {
    Event {
        id: format!("00000000-0000-4000-8000-{id:012}"),
        device_id: dev.into(),
        seq,
        hlc_ms: hlc,
        hlc_counter: 0,
        ty: "x.unknown".into(),
        payload: json!({}),
        source: Source::User,
        command_key: None,
    }
}

async fn raw_endpoint() -> (Endpoint, String) {
    let key = SecretKey::generate();
    let id = key.public().to_string();
    let ep = Endpoint::builder(presets::Minimal)
        .relay_mode(RelayMode::Disabled)
        .clear_ip_transports()
        .bind_addr("127.0.0.1:0")
        .unwrap()
        .secret_key(key)
        .bind()
        .await
        .unwrap();
    (ep, id)
}

async fn dial(ep: &Endpoint, node: &T) -> Connection {
    let addr = EndpointTicket::from_str(&node.endpoint_ticket().await).unwrap().endpoint_addr().clone();
    ep.connect(addr, ALPN).await.unwrap()
}

#[tokio::test]
async fn a6_sync_sends_each_device_in_seq_order_even_when_key_order_differs() {
    let opts = SyncOptions { events_per_frame: 2, ..SyncOptions::local() };
    let (a, b) = (node_with(opts).await, node().await);
    trust(&a, &b);
    // Device X's later seqs carry earlier hlc values, so total order is the reverse of seq order.
    let events: Vec<Event> = (1..=6u64).map(|s| plain(s as u32, "X", s, T0 + (7 - s as i64) * 1000)).collect();
    a.store().lock().unwrap().ingest(&events).unwrap();
    // Chunked in total order, frame 1 would carry seqs 6 and 5 and the receiver would see a gap.
    let report = b.sync_with(&a.endpoint_ticket().await).await.unwrap();
    assert_eq!(report.received, 6);
    assert_eq!(ids(&a), ids(&b));
    assert_eq!(b.store().lock().unwrap().version_vector().unwrap()["X"], 6);
    assert_consistent(&b);
}

#[tokio::test]
async fn a5_an_invalid_event_aborts_the_frame_and_leaves_no_hole() {
    let a = node().await;
    let (raw, raw_id) = raw_endpoint().await;
    a.trust_device(&raw_id, "raw").unwrap();
    let conn = dial(&raw, &a).await;
    let (mut send, mut recv) = conn.open_bi().await.unwrap();
    write_frame(&mut send, &Frame::Hello { device_id: raw_id.clone(), vv: Default::default(), live: false }).await.unwrap();
    assert!(matches!(read_frame(&mut recv).await.unwrap(), Frame::Hello { .. }));
    loop {
        if matches!(read_frame(&mut recv).await.unwrap(), Frame::Done) {
            break;
        }
    }
    // The review's repro: seq 1 valid, seq 2 with payload `[]`, seq 3 valid.
    let mut bad = plain(2, &raw_id, 2, T0 + 2);
    bad.payload = json!([]);
    let frame = vec![plain(1, &raw_id, 1, T0 + 1), bad, plain(3, &raw_id, 3, T0 + 3)];
    write_frame(&mut send, &Frame::Events { events: frame }).await.unwrap();
    write_frame(&mut send, &Frame::Done).await.unwrap();
    let end = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            match read_frame(&mut recv).await {
                Ok(Frame::Bye) | Err(_) => return,
                Ok(_) => {}
            }
        }
    })
    .await;
    assert!(end.is_ok(), "session was not aborted");
    assert!(!a.store().lock().unwrap().version_vector().unwrap().contains_key(&raw_id), "nothing was stored");
    assert_consistent(&a);
}

#[tokio::test]
async fn r3_2_far_future_events_are_skipped_without_holes_and_arrive_when_the_clock_catches_up() {
    let a = node().await;
    let clock = Arc::new(AtomicI64::new(T0));
    {
        let c = clock.clone();
        a.store().lock().unwrap().set_clock(move || c.load(Ordering::SeqCst));
    }
    // One event per frame: the future one and a later one cross frame boundaries.
    let b = node_with(SyncOptions { events_per_frame: 1, ..SyncOptions::local() }).await;
    trust(&a, &b);
    let first = start(&b, T0);
    let future = start(&b, T0 + 2 * DAY);
    let later = start(&b, T0 + 2 * DAY + 1000);
    a.store().lock().unwrap().apply(
        Command { body: CommandBody::Start { kind: Kind::Focus, planned_ms: 60_000, label: None, project: None }, command_key: None },
        Source::User,
        T0 + 10,
    )
    .unwrap();

    let r = a.sync_with(&b.endpoint_ticket().await).await.unwrap();
    assert_eq!(r.received, 1, "only the event from before the horizon was stored");
    let got = ids(&a);
    assert!(got.contains(&first.id) && !got.contains(&future.id) && !got.contains(&later.id));
    assert_eq!(a.store().lock().unwrap().version_vector().unwrap()[b.device_id()], 1);
    // A's own running block was not completed by the poisoned clock, and A's next event is at A's time.
    let timer = a.store().lock().unwrap().timer(T0 + 20);
    assert_eq!(timer.status, TimerStatus::Running);
    let own = cmd(&a, CommandBody::Pause, T0 + 30).unwrap();
    assert_eq!(own.hlc_ms, T0 + 30);

    // The clock catches up: the same events are offered again and now stored, in seq order.
    clock.store(T0 + 2 * DAY, Ordering::SeqCst);
    let r = a.sync_with(&b.endpoint_ticket().await).await.unwrap();
    assert_eq!(r.received, 2);
    let got = ids(&a);
    assert!(got.contains(&future.id) && got.contains(&later.id));
    assert_eq!(a.store().lock().unwrap().version_vector().unwrap()[b.device_id()], 3);
    assert_consistent(&a);
}

#[tokio::test]
async fn r3_4_a_session_ends_with_an_error_after_the_event_cap_and_the_next_one_continues() {
    let a = node_with(SyncOptions { max_events_per_session: 50, ..SyncOptions::local() }).await;
    let b = node_with(SyncOptions { events_per_frame: 20, ..SyncOptions::local() }).await;
    trust(&a, &b);
    for i in 0..120 {
        start(&b, T0 + i);
    }
    let ticket = b.endpoint_ticket().await;
    assert!(a.sync_with(&ticket).await.is_err(), "60 events arrive, over the cap of 50");
    let stored = count(&a);
    assert!((50..120).contains(&stored), "stored what arrived before the abort: {stored}");
    assert_consistent(&a);
    // The next session continues where the last one stopped (and hits the cap again).
    let _ = a.sync_with(&ticket).await;
    assert_eq!(count(&a), 120);
    assert_eq!(ids(&a), ids(&b));
}

#[tokio::test]
async fn r3_6_unauthenticated_connections_are_capped_and_paired_devices_are_not() {
    let a = node_with(SyncOptions { max_unauthenticated: 2, ..SyncOptions::local() }).await;
    let paired = node().await;
    trust(&a, &paired);

    let (r1, id1) = raw_endpoint().await;
    let (r2, id2) = raw_endpoint().await;
    let (r3, _) = raw_endpoint().await;
    // Two connections that open a stream and then say nothing hold both slots.
    let c1 = dial(&r1, &a).await;
    let _s1 = c1.open_bi().await.unwrap();
    let c2 = dial(&r2, &a).await;
    let _s2 = c2.open_bi().await.unwrap();
    eventually("both slots taken", Duration::from_secs(3), || a.has_session(&id1) && a.has_session(&id2)).await;

    // The third is dropped at once, not after the 10 s first-frame timeout.
    let c3 = dial(&r3, &a).await;
    assert!(tokio::time::timeout(Duration::from_secs(2), c3.closed()).await.is_ok(), "third connection was not dropped");
    assert!(tokio::time::timeout(Duration::from_millis(300), c1.closed()).await.is_err(), "first one is still held");

    // A paired Device is not counted against the cap.
    start(&paired, T0);
    paired.sync_with(&a.endpoint_ticket().await).await.unwrap();
    assert_eq!(count(&a), 1);

    // Freeing a slot lets the next connection in.
    c1.close(0u32.into(), b"done");
    let (r4, id4) = raw_endpoint().await;
    let c4 = dial(&r4, &a).await;
    let _s4 = c4.open_bi().await.unwrap();
    eventually("slot reused", Duration::from_secs(3), || a.has_session(&id4)).await;
}
