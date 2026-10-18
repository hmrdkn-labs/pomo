mod common;
use common::*;
use iroh::endpoint::presets;
use iroh::{Endpoint, RelayMode, SecretKey};
use iroh_tickets::endpoint::EndpointTicket;
use pomo_core::*;
use pomo_sync::wire::{read_frame, write_frame, Frame, ALPN};
use pomo_sync::{Error, SyncOptions};
use std::str::FromStr;
use std::time::Duration;

#[tokio::test]
async fn a_diverged_logs_converge_in_one_session() {
    let (a, b) = (node().await, node().await);
    trust(&a, &b);
    for i in 0..5 {
        start(&a, T0 + i * 1000);
        start(&b, T0 + i * 1000 + 500);
    }
    let report = a.sync_with(&b.endpoint_ticket().await).await.unwrap();
    assert_eq!((report.sent, report.received), (5, 5));
    assert_eq!(ids(&a), ids(&b));
    assert_eq!(count(&a), 10);
    assert_consistent(&a);
    assert_consistent(&b);
    // Idempotent: a second session moves nothing.
    let again = b.sync_with(&a.endpoint_ticket().await).await.unwrap();
    assert_eq!((again.sent, again.received), (0, 0));
}

#[tokio::test]
async fn b_events_relay_through_the_middle_device() {
    let (a, b, c) = (node().await, node().await, node().await);
    trust(&a, &b);
    trust(&b, &c);
    let ev = start(&a, T0);
    a.sync_with(&b.endpoint_ticket().await).await.unwrap();
    assert!(!c.is_paired(a.device_id()).unwrap());
    c.sync_with(&b.endpoint_ticket().await).await.unwrap();
    assert_eq!(ids(&c), vec![ev.id.clone()]);
    // And back: C's event reaches A through B.
    let ev2 = start(&c, T0 + 10);
    c.sync_with(&b.endpoint_ticket().await).await.unwrap();
    a.sync_with(&b.endpoint_ticket().await).await.unwrap();
    assert!(ids(&a).contains(&ev2.id));
    assert_eq!(ids(&a), ids(&c));
    assert_consistent(&a);
}

fn tamper_secret(ticket: &str) -> String {
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    use base64::Engine;
    let raw = URL_SAFE_NO_PAD.decode(ticket.strip_prefix("pomo-pair:").unwrap()).unwrap();
    let mut v: serde_json::Value = serde_json::from_slice(&raw).unwrap();
    v["secret"] = "AAAAAAAAAAAAAAAAAAAAAA".into();
    format!("pomo-pair:{}", URL_SAFE_NO_PAD.encode(serde_json::to_vec(&v).unwrap()))
}

fn rejected(r: Result<impl std::fmt::Debug, Error>) -> String {
    match r {
        Err(Error::Rejected(reason)) => reason,
        other => panic!("expected a rejection, got {other:?}"),
    }
}

#[tokio::test]
async fn c_pairing_happy_path() {
    let (a, b) = (node().await, node().await);
    let ev = start(&a, T0);
    let ticket = a.pairing_ticket("laptop").await.unwrap();
    assert!(ticket.starts_with("pomo-pair:"));
    let out = b.pair(&ticket, "phone").await.unwrap();
    assert_eq!((out.device_id.as_str(), out.name.as_str()), (a.device_id(), "laptop"));
    assert!(a.is_paired(b.device_id()).unwrap() && b.is_paired(a.device_id()).unwrap());
    assert_eq!(out.sync.received, 1);
    assert_eq!(ids(&b), vec![ev.id]);
    // Later sessions need no ticket.
    start(&b, T0 + 5);
    b.sync_with(&a.endpoint_ticket().await).await.unwrap();
    assert_eq!(ids(&a), ids(&b));
}

#[tokio::test]
async fn c_pairing_wrong_secret_expired_and_reused() {
    let (a, b, c) = (node().await, node().await, node().await);
    let ticket = a.pairing_ticket("a").await.unwrap();
    assert_eq!(rejected(b.pair(&tamper_secret(&ticket), "b").await), "bad_secret");
    assert!(!a.is_paired(b.device_id()).unwrap() && !b.is_paired(a.device_id()).unwrap());
    // A wrong guess does not burn the real ticket.
    b.pair(&ticket, "b").await.unwrap();
    assert_eq!(rejected(c.pair(&ticket, "c").await), "used");
    assert!(!a.is_paired(c.device_id()).unwrap());

    let short = node_with(SyncOptions { ticket_ttl: Duration::from_millis(150), ..SyncOptions::local() }).await;
    let ticket = short.pairing_ticket("s").await.unwrap();
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert_eq!(rejected(c.pair(&ticket, "c").await), "expired");
    assert!(!short.is_paired(c.device_id()).unwrap());
}

#[tokio::test]
async fn d_unpaired_and_revoked_are_rejected() {
    let (a, b, c) = (node().await, node().await, node().await);
    trust(&a, &b);
    let ev = start(&c, T0);
    // C refuses to dial a Device it has not paired with.
    assert!(matches!(c.sync_with(&a.endpoint_ticket().await).await, Err(Error::NotPaired(_))));
    // C trusts A one-sidedly; A's listener rejects the unpaired C and stores nothing.
    c.trust_device(a.device_id(), "a").unwrap();
    assert_eq!(rejected(c.sync_with(&a.endpoint_ticket().await).await), "unpaired");
    assert_eq!(count(&a), 0);
    // Revoked.
    start(&b, T0 + 1);
    a.revoke(b.device_id()).unwrap();
    assert_eq!(rejected(b.sync_with(&a.endpoint_ticket().await).await), "revoked");
    assert_eq!(count(&a), 0);
    assert!(!ids(&a).contains(&ev.id));
    // Re-pairing is an explicit act and lifts the revocation.
    let ticket = a.pairing_ticket("a").await.unwrap();
    b.pair(&ticket, "b").await.unwrap();
    assert_eq!(count(&a), 1);
}

#[tokio::test]
async fn e_live_mode_forwards_within_two_seconds() {
    let (a, b) = (node().await, node().await);
    trust(&a, &b);
    a.set_live(true);
    b.set_live(true);
    let mut rx = b.subscribe();
    let report = a.sync_with(&b.endpoint_ticket().await).await.unwrap();
    assert!(report.live);
    let ev = start(&a, T0);
    eventually("event on B", Duration::from_secs(2), || ids(&b).contains(&ev.id)).await;
    let seen = rx.try_recv().unwrap();
    assert_eq!(seen[0].id, ev.id);
    // And the other way, over the same session.
    let ev2 = start(&b, T0 + 1);
    eventually("event on A", Duration::from_secs(2), || ids(&a).contains(&ev2.id)).await;
    assert_consistent(&b);
    // Turning live off ends the session; the next dial is a plain exchange.
    a.set_live(false);
    b.set_live(false);
    tokio::time::sleep(Duration::from_millis(300)).await;
    let ev3 = start(&a, T0 + 2);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(!ids(&b).contains(&ev3.id));
    let r = a.sync_with(&b.endpoint_ticket().await).await.unwrap();
    assert_eq!((r.sent, r.received, r.live), (1, 0, false));
}

#[tokio::test]
async fn f_interrupted_session_leaves_a_consistent_store_and_next_completes() {
    let opts = SyncOptions { events_per_frame: 10, drop_after_frames: Some(2), ..SyncOptions::local() };
    let a = node_with(opts.clone()).await;
    let b = node_with(SyncOptions { drop_after_frames: None, ..opts }).await;
    trust(&a, &b);
    for i in 0..35 {
        start(&a, T0 + i);
    }
    let ticket = a.endpoint_ticket().await;
    assert!(b.sync_with(&ticket).await.is_err());
    let partial = count(&b);
    assert_eq!(partial, 20, "two whole frames arrived before the drop");
    assert_consistent(&b);
    let r = b.sync_with(&ticket).await.unwrap();
    assert_eq!(r.received, 15);
    assert_eq!(ids(&a), ids(&b));
    assert_consistent(&b);
}

#[tokio::test]
async fn g_seq_conflict_aborts_and_stores_nothing_from_the_frame() {
    let a = node().await;
    let honest = start(&a, T0);
    start(&a, T0 + 1);
    let raw_key = SecretKey::generate();
    let raw_id = raw_key.public().to_string();
    a.trust_device(&raw_id, "raw").unwrap();
    let raw = Endpoint::builder(presets::Minimal)
        .relay_mode(RelayMode::Disabled)
        .clear_ip_transports()
        .bind_addr("127.0.0.1:0")
        .unwrap()
        .secret_key(raw_key)
        .bind()
        .await
        .unwrap();
    let addr = EndpointTicket::from_str(&a.endpoint_ticket().await).unwrap().endpoint_addr().clone();
    let conn = raw.connect(addr, ALPN).await.unwrap();
    let (mut send, mut recv) = conn.open_bi().await.unwrap();
    write_frame(&mut send, &Frame::Hello { device_id: raw_id.clone(), vv: Default::default() }).await.unwrap();
    assert!(matches!(read_frame(&mut recv).await.unwrap(), Frame::Hello { .. }));
    let mk = |dev: &str, seq: u64, id: &str| Event {
        id: id.into(),
        device_id: dev.into(),
        seq,
        hlc_ms: T0 + 100 + seq as i64,
        hlc_counter: 0,
        ty: "timer.started".into(),
        payload: serde_json::json!({"block_id": format!("blk-{id}"), "kind": "focus", "planned_ms": 1000}),
        source: Source::User,
        command_key: None,
    };
    // Drain A's own events until its `done`.
    loop {
        if matches!(read_frame(&mut recv).await.unwrap(), Frame::Done) {
            break;
        }
    }
    let good = mk(&raw_id, 1, "00000000-0000-4000-8000-000000000001");
    let forged = mk(a.device_id(), 1, "00000000-0000-4000-8000-0000000000ff");
    write_frame(&mut send, &Frame::Events { events: vec![good.clone(), forged] }).await.unwrap();
    write_frame(&mut send, &Frame::Done).await.unwrap();
    // A drops the session.
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
    assert_eq!(count(&a), 2);
    assert!(ids(&a).contains(&honest.id) && !ids(&a).contains(&good.id));
    assert_consistent(&a);
    // The honest frame alone is accepted by a fresh session.
    let conn = raw.connect(EndpointTicket::from_str(&a.endpoint_ticket().await).unwrap().endpoint_addr().clone(), ALPN)
        .await
        .unwrap();
    let (mut send, mut recv) = conn.open_bi().await.unwrap();
    write_frame(&mut send, &Frame::Hello { device_id: raw_id.clone(), vv: Default::default() }).await.unwrap();
    assert!(matches!(read_frame(&mut recv).await.unwrap(), Frame::Hello { .. }));
    write_frame(&mut send, &Frame::Events { events: vec![good.clone()] }).await.unwrap();
    write_frame(&mut send, &Frame::Done).await.unwrap();
    eventually("honest event stored", Duration::from_secs(3), || ids(&a).contains(&good.id)).await;
}

#[tokio::test]
#[ignore = "needs internet: pairs and syncs through the real n0 relays"]
async fn n0_relay_pairing_and_sync() {
    let (a, b) = (node_with(SyncOptions::default()).await, node_with(SyncOptions::default()).await);
    let ev = start(&a, T0);
    let ticket = a.pairing_ticket("a").await.unwrap();
    let out = b.pair(&ticket, "b").await.unwrap();
    assert_eq!(out.sync.received, 1);
    let ev2 = start(&b, T0 + 1);
    b.sync_with(a.device_id()).await.unwrap();
    assert!(ids(&a).contains(&ev2.id) && ids(&b).contains(&ev.id));
}

#[tokio::test]
async fn key_file_is_private_and_device_id_survives_restart() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("pomo.db");
    let first = pomo_sync::SyncNode::open(&db, SyncOptions::local()).await.unwrap();
    let id = first.device_id().to_string();
    assert_eq!(first.store().lock().unwrap().device_id(), id);
    first.shutdown().await;
    drop(first);
    let mode = std::fs::metadata(dir.path().join("meta/key")).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o600);
    let second = pomo_sync::SyncNode::open(&db, SyncOptions::local()).await.unwrap();
    assert_eq!(second.device_id(), id);
}
