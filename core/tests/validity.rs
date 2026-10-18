//! Regression tests for the validity bounds, seq holes, far-future clocks, store versioning and
//! query limits (review findings A1-A11, R3-1..R3-5, R2-4).

use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;

use pomo_core::*;
use serde_json::{json, Value};

const T: i64 = 1_700_000_000_000;
const DAY: i64 = 86_400_000;

fn ev(id: u32, dev: &str, seq: u64, hlc: i64, ctr: u32, ty: &str, payload: Value) -> Event {
    Event {
        id: format!("00000000-0000-4000-8000-{id:012}"),
        device_id: dev.into(),
        seq,
        hlc_ms: hlc,
        hlc_counter: ctr,
        ty: ty.into(),
        payload,
        source: Source::User,
        command_key: None,
    }
}

fn started(id: u32, dev: &str, seq: u64, hlc: i64, planned: i64) -> Event {
    ev(id, dev, seq, hlc, 0, "timer.started", json!({"block_id": format!("b{id}"), "kind": "focus", "planned_ms": planned}))
}

fn cmd(body: CommandBody) -> Command {
    Command { body, command_key: None }
}

fn start_cmd(planned_ms: i64) -> Command {
    cmd(CommandBody::Start { kind: Kind::Focus, planned_ms, label: None, project: None })
}

#[test]
fn durations_outside_24h_are_rejected_never_stored() {
    let mut s = Store::open_in_memory("me").unwrap();
    // The review's repro: a legal start, then an extend of i64::MAX.
    let events = [
        started(1, "peer", 1, T, 1_500_000),
        ev(2, "peer", 2, T + 1, 0, "timer.extended", json!({"block_id": "b1", "add_ms": i64::MAX})),
    ];
    let r = s.ingest(&events).unwrap();
    assert_eq!((r.inserted, r.invalid.len()), (1, 1));
    let b = &s.blocks(Range::ALL, T + 10).unwrap()[0];
    assert_eq!(b.planned_ms, 1_500_000);
    // Bounds are inclusive at 24 h and exclusive beyond; zero and negatives never pass.
    for (i, (planned, ok)) in [(DAY, true), (DAY + 1, false), (0, false), (-1, false), (i64::MAX, false)].into_iter().enumerate() {
        let r = s.ingest(&[started(10 + i as u32, "other", 1 + i as u64, T, planned)]).unwrap();
        assert_eq!(r.inserted == 1, ok, "planned_ms {planned}");
    }
    // Commands face the same bounds and write nothing.
    let before = s.events().unwrap().len();
    for planned in [0, DAY + 1, i64::MAX] {
        assert!(matches!(s.apply(start_cmd(planned), Source::User, T + 100), Err(Error::InvalidArgument(_))));
    }
    s.apply(start_cmd(60_000), Source::User, T + 100).unwrap();
    for add in [0, DAY + 1, i64::MAX] {
        assert!(matches!(
            s.apply(cmd(CommandBody::Extend { add_ms: add }), Source::User, T + 200),
            Err(Error::InvalidArgument(_))
        ));
    }
    assert_eq!(s.events().unwrap().len(), before + 1);
    // Status and stats still work after all of it.
    s.timer(T + 300);
    s.stats(Range::ALL, 0, T + 300).unwrap();
}

#[test]
fn extend_past_48h_is_a_reducer_noop_and_a_command_error() {
    let mut s = Store::open_in_memory("me").unwrap();
    s.ingest(&[
        started(1, "peer", 1, T, DAY),
        ev(2, "peer", 2, T + 1, 0, "timer.extended", json!({"block_id": "b1", "add_ms": DAY})),
        // 48 h exactly is allowed; one millisecond more is not.
        ev(3, "peer", 3, T + 2, 0, "timer.extended", json!({"block_id": "b1", "add_ms": 1})),
    ])
    .unwrap();
    assert_eq!(s.events().unwrap().len(), 3, "the no-op event stays in the log");
    assert_eq!(s.blocks(Range::ALL, T + 10).unwrap()[0].planned_ms, 2 * DAY);
    assert_eq!(s.timer(T + 10).remaining_ms, Some(2 * DAY - 10));
    // The same rule at command level, in a store of its own.
    let mut s = Store::open_in_memory("me").unwrap();
    s.apply(start_cmd(DAY), Source::User, T).unwrap();
    s.apply(cmd(CommandBody::Extend { add_ms: DAY }), Source::User, T + 1).unwrap();
    assert!(matches!(s.apply(cmd(CommandBody::Extend { add_ms: 1 }), Source::User, T + 2), Err(Error::InvalidArgument(_))));
    assert_eq!(s.events().unwrap().len(), 2);
}

#[test]
fn hlc_bounds_and_counter_overflow() {
    let mut s = Store::open_in_memory("me").unwrap();
    // The review's repros: u32::MAX counter, a far-future hlc_ms, a negative one.
    let bad = [
        ev(1, "b", 1, 5000, u32::MAX, "x.unknown", json!({})),
        ev(2, "c", 1, i64::MAX - 1000, 0, "x.unknown", json!({})),
        ev(3, "d", 1, -1, 0, "x.unknown", json!({})),
        ev(4, "e", 1, MAX_HLC_MS + 1, 0, "x.unknown", json!({})),
        ev(5, "f", 1, 5000, MAX_HLC_COUNTER + 1, "x.unknown", json!({})),
    ];
    for e in &bad {
        let r = s.ingest(std::slice::from_ref(e)).unwrap();
        assert_eq!((r.inserted, r.invalid.len()), (0, 1), "{e:?}");
    }
    assert!(s.events().unwrap().is_empty());
    // Day maths and reads at the extremes do not overflow.
    s.stats(Range::ALL, 1440, i64::MAX).unwrap();
    s.timer(i64::MAX);
    // A counter at its bound is legal; the next local event moves hlc_ms on instead of wrapping.
    s.ingest(&[ev(6, "b", 1, 5000, MAX_HLC_COUNTER, "x.unknown", json!({}))]).unwrap();
    let e = s.apply(start_cmd(60_000), Source::User, 1).unwrap();
    assert_eq!((e.hlc_ms, e.hlc_counter), (5001, 0));
    let all = s.events().unwrap();
    assert_eq!(all.last().unwrap().id, e.id, "the local event sorts after the peer's");
    // seq runs of the issuing Device stay in key order.
    let e2 = s.apply(cmd(CommandBody::Stop), Source::User, 1).unwrap();
    assert_eq!((e2.hlc_ms, e2.hlc_counter), (5001, 1));
}

#[test]
fn identity_fields_and_payload_size_are_bounded() {
    let mut s = Store::open_in_memory("me").unwrap();
    let mut n = 0;
    let mut try_ingest = |mut e: Event, tweak: &dyn Fn(&mut Event)| {
        n += 1;
        e.seq = n;
        e.id = format!("00000000-0000-4000-8000-{n:012}");
        e.device_id = format!("dev{n}");
        e.command_key = None;
        tweak(&mut e);
        s.ingest(&[e]).unwrap().inserted == 1
    };
    let base = ev(1, "x", 1, T, 0, "block.labeled", json!({"block_id": "b", "label": "l"}));
    assert!(try_ingest(base.clone(), &|_| {}));
    for bad_id in ["x", "", "00000000-0000-4000-8000-00000000000A", "00000000000040008000000000000001", "00000000-0000-4000-8000-0000000000012"] {
        assert!(!try_ingest(base.clone(), &|e| e.id = bad_id.into()), "id {bad_id:?}");
    }
    assert!(try_ingest(base.clone(), &|e| e.device_id = "d".repeat(128)));
    assert!(!try_ingest(base.clone(), &|e| e.device_id = "d".repeat(129)));
    assert!(try_ingest(base.clone(), &|e| e.command_key = Some("k".repeat(128))));
    assert!(!try_ingest(base.clone(), &|e| e.command_key = Some("k".repeat(129))));
    assert!(!try_ingest(base.clone(), &|e| e.source = Source::Agent("a".repeat(129))));
    assert!(!try_ingest(base.clone(), &|e| e.seq = MAX_SEQ + 1));
    assert!(try_ingest(base.clone(), &|e| e.seq = MAX_SEQ));
    // 16 KiB of payload: just under passes, over does not.
    let pad = |len: usize| move |e: &mut Event| e.payload = json!({"block_id": "b", "label": "x".repeat(len)});
    assert!(try_ingest(base.clone(), &pad(16 * 1024 - 40)));
    assert!(!try_ingest(base.clone(), &pad(16 * 1024)));
    // A local command with an oversized label is refused and writes nothing.
    let before = s.events().unwrap().len();
    s.apply(start_cmd(1000), Source::User, T + 1).unwrap();
    let big = CommandBody::Label { block_id: None, label: Some("x".repeat(20_000)), project: None };
    assert!(matches!(s.apply(cmd(big), Source::User, T + 2), Err(Error::InvalidArgument(_))));
    let long_key = Command { body: CommandBody::Pause, command_key: Some("k".repeat(129)) };
    assert!(matches!(s.apply(long_key, Source::User, T + 3), Err(Error::InvalidArgument(_))));
    assert_eq!(s.events().unwrap().len(), before + 1);
}

#[test]
fn local_events_with_out_of_range_time_are_refused() {
    let mut s = Store::open_in_memory("me").unwrap();
    for now in [-1, MAX_HLC_MS + 1, i64::MAX, i64::MIN] {
        assert!(matches!(s.apply(start_cmd(1000), Source::User, now), Err(Error::InvalidArgument(_))), "now {now}");
    }
    assert!(s.events().unwrap().is_empty());
    s.apply(start_cmd(1000), Source::User, MAX_HLC_MS).unwrap();
}

#[test]
fn an_invalid_event_never_leaves_a_seq_hole() {
    let blocks = |id| json!({"block_id": format!("b{id}"), "kind": "focus", "planned_ms": 1000});
    let mk = |id: u32, seq: u64, payload: Value| ev(id, "B", seq, T + seq as i64, 0, "timer.started", payload);
    // The review's repro: B/1 valid, B/2 payload `[]`, B/3 valid.
    let frame = [mk(1, 1, blocks(1)), mk(2, 2, json!([])), mk(3, 3, blocks(3))];

    let mut s = Store::open_in_memory("me").unwrap();
    let r = s.ingest(&frame).unwrap();
    assert_eq!((r.inserted, r.invalid.len()), (1, 2), "B/3 follows the invalid B/2");
    assert_eq!(s.version_vector().unwrap()["B"], 1);

    // The atomic variant rejects the whole frame, typed, and stores nothing.
    let mut s = Store::open_in_memory("me").unwrap();
    assert!(matches!(s.ingest_atomic(&frame), Err(Error::InvalidArgument(_))));
    assert!(s.events().unwrap().is_empty());
    assert!(s.projected_blocks(Range::ALL).unwrap().is_empty());

    // The order inside the call does not matter, and other Devices are unaffected.
    let mut s = Store::open_in_memory("me").unwrap();
    let other = ev(9, "C", 1, T, 0, "x.unknown", json!({}));
    let r = s.ingest(&[mk(3, 3, blocks(3)), other, mk(2, 2, json!([])), mk(1, 1, blocks(1))]).unwrap();
    assert_eq!(r.inserted, 2);
    let vv = s.version_vector().unwrap();
    assert_eq!((vv["B"], vv["C"]), (1, 1));
}

#[test]
fn far_future_events_wait_until_the_receivers_clock_catches_up() {
    let clock = Arc::new(AtomicI64::new(T));
    let mut s = Store::open_in_memory("me").unwrap();
    {
        let c = clock.clone();
        s.set_clock(move || c.load(Ordering::SeqCst));
    }
    s.apply(start_cmd(60_000), Source::User, T).unwrap();
    // A peer event 2 days ahead, then an ordinary one of the same Device in the same call.
    let far = ev(1, "peer", 1, T + 2 * DAY, 0, "timer.paused", json!({"block_id": "nope"}));
    let after = ev(2, "peer", 2, T + 5, 0, "x.unknown", json!({}));
    let r = s.ingest(&[far.clone(), after.clone()]).unwrap();
    assert_eq!((r.inserted, r.future.len(), r.invalid.len()), (0, 2, 0));
    assert!(!s.version_vector().unwrap().contains_key("peer"), "the peer's entry does not advance");
    // The next local command is issued at the local clock, not the peer's.
    let local = s.apply(cmd(CommandBody::Pause), Source::User, T + 10).unwrap();
    assert_eq!(local.hlc_ms, T + 10);
    // The atomic variant skips too: not an error, nothing stored.
    let r = s.ingest_atomic(&[far.clone(), after.clone()]).unwrap();
    assert_eq!((r.inserted, r.future.len()), (0, 2));
    // 23 h ahead is within tolerance.
    let near = ev(3, "near", 1, T + 23 * 3_600_000, 0, "x.unknown", json!({}));
    assert_eq!(s.ingest(&[near]).unwrap().inserted, 1);
    // Offered again once the clock has caught up.
    clock.store(T + 2 * DAY, Ordering::SeqCst);
    let r = s.ingest(&[far, after]).unwrap();
    assert_eq!((r.inserted, r.future.len()), (2, 0));
    assert_eq!(s.version_vector().unwrap()["peer"], 2);
}

#[test]
fn a_far_future_event_does_not_complete_the_running_block() {
    let clock = Arc::new(AtomicI64::new(T));
    let mut s = Store::open_in_memory("me").unwrap();
    {
        let c = clock.clone();
        s.set_clock(move || c.load(Ordering::SeqCst));
    }
    s.apply(start_cmd(60_000), Source::User, T).unwrap();
    // The review's repro: any event with a year-2090 hlc_ms settles the live block.
    let far = ev(1, "peer", 1, 3_800_000_000_000, 0, "x.unknown", json!({}));
    assert_eq!(s.ingest(&[far]).unwrap().future.len(), 1);
    assert_eq!(s.timer(T + 1000).status, TimerStatus::Running);
    let st = s.stats(Range::ALL, 0, T + 1000).unwrap();
    assert_eq!((st.completed_focus, st.focus_ms_total), (0, 0));
}

#[test]
fn events_after_clamps_the_peer_vector_and_pages() {
    let mut s = Store::open_in_memory("me").unwrap();
    let events: Vec<Event> = (1..=5).map(|i| started(i, "peer", u64::from(i), T + i64::from(i), 1000)).collect();
    s.ingest(&events).unwrap();
    // A vector entry above i64::MAX is clamped (it already means "has everything").
    let vv: VersionVector = [("peer".to_string(), u64::MAX)].into();
    assert!(s.events_after(&vv).unwrap().is_empty());
    // Paging: each page is a seq prefix per Device; advancing the vector continues.
    let mut vv = VersionVector::new();
    let mut seen = Vec::new();
    loop {
        let page = s.events_after_limit(&vv, 2).unwrap();
        if page.is_empty() {
            break;
        }
        assert!(page.len() <= 2);
        for e in &page {
            vv.insert(e.device_id.clone(), e.seq);
        }
        seen.extend(page);
    }
    assert_eq!(seen, events);
}

#[test]
fn block_queries_apply_range_kind_and_limit_in_sql() {
    let mut s = Store::open_in_memory("me").unwrap();
    let mk = |id: u32, kind: &str, at: i64| {
        ev(id, "x", u64::from(id), at, 0, "timer.started", json!({"block_id": format!("b{id}"), "kind": kind, "planned_ms": 1000}))
    };
    // Ten blocks, one per minute, every third a break; each is over long before the next starts.
    let events: Vec<Event> =
        (1..=10).map(|i| mk(i, if i % 3 == 0 { "short_break" } else { "focus" }, T + i64::from(i) * 60_000)).collect();
    s.ingest(&events).unwrap();
    let now = T + 20 * 60_000;
    let page = s.blocks_page(Range::ALL, None, 3, now).unwrap();
    let ids: Vec<&str> = page.iter().map(|b| b.id.as_str()).collect();
    assert_eq!(ids, ["b10", "b9", "b8"], "newest first");
    let focus = s.blocks_page(Range { from_ms: T + 2 * 60_000, to_ms: T + 8 * 60_000 }, Some(Kind::Focus), 100, now).unwrap();
    let ids: Vec<&str> = focus.iter().map(|b| b.id.as_str()).collect();
    assert_eq!(ids, ["b7", "b5", "b4", "b2"]);
    // The live block is settled at `now` by the single-block lookup too.
    let b = s.block("b10", now).unwrap().unwrap();
    assert_eq!((b.phase, b.outcome), (Phase::Ended, Some(Outcome::Completed)));
    assert_eq!(s.block("nope", now).unwrap(), None);
}

#[test]
fn stats_read_only_the_range_and_count_a_block_that_ran_out_unobserved() {
    let mut s = Store::open_in_memory("me").unwrap();
    // Two completed focus days in the past, today's block ran out without any later event.
    let day = |n: i64| T - n * DAY;
    s.ingest(&[
        started(1, "x", 1, day(2), 60_000),
        started(2, "x", 2, day(1), 60_000),
        started(3, "x", 3, day(0), 60_000),
    ])
    .unwrap();
    let now = day(0) + 120_000;
    let st = s.stats(Range { from_ms: day(0) - 1000, to_ms: now }, 0, now).unwrap();
    assert_eq!((st.completed_focus, st.focus_ms_total), (1, 60_000));
    assert_eq!(st.streak_days, 3, "the streak looks beyond the range and counts the settled live block");
}

#[test]
fn first_open_is_one_transaction_and_versions_are_strict() {
    let dir = std::env::temp_dir().join(format!("pomo-core-validity-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let raw = |p: &std::path::Path| rusqlite::Connection::open(p).unwrap();
    let version = |c: &rusqlite::Connection| -> String {
        c.query_row("SELECT value FROM meta WHERE key='schema_version'", [], |r| r.get(0)).unwrap()
    };

    // A fresh store has its schema and meta rows together, at the newest version.
    let fresh = dir.join("fresh.db");
    drop(Store::open(&fresh, "me").unwrap());
    let c = raw(&fresh);
    assert_eq!(version(&c), "2");
    let id: String = c.query_row("SELECT value FROM meta WHERE key='device_id'", [], |r| r.get(0)).unwrap();
    assert_eq!(id, "me");
    drop(c);

    // The review's crash state (tables, no meta rows) is reported as damaged, not as "no rows".
    let crashed = dir.join("crashed.db");
    raw(&crashed).execute_batch(include_str!("../../spec/migrations/0001_init.sql")).unwrap();
    match Store::open(&crashed, "me") {
        Err(Error::InvalidState(m)) => assert!(m.contains("damaged"), "{m}"),
        other => panic!("{:?}", other.err()),
    }

    // A version that is not a number used to re-run migration 0002 and die on "table exists".
    for bad in ["abc", "", "0", "-3"] {
        let p = dir.join("bad.db");
        let _ = std::fs::remove_file(&p);
        drop(Store::open(&p, "me").unwrap());
        raw(&p).execute("UPDATE meta SET value = ?1 WHERE key='schema_version'", [bad]).unwrap();
        match Store::open(&p, "me") {
            Err(Error::InvalidState(m)) => assert!(m.contains("damaged"), "{bad}: {m}"),
            other => panic!("{bad}: {:?}", other.err()),
        }
    }

    // A store from a newer build is refused, untouched.
    let newer = dir.join("newer.db");
    drop(Store::open(&newer, "me").unwrap());
    raw(&newer).execute("UPDATE meta SET value = '3' WHERE key='schema_version'", []).unwrap();
    match Store::open(&newer, "me") {
        Err(Error::InvalidState(m)) => assert!(m.contains("newer"), "{m}"),
        other => panic!("{:?}", other.err()),
    }
    assert_eq!(version(&raw(&newer)), "3");

    // A migration that fails after its first statement rolls back completely, version included.
    let v1 = dir.join("v1.db");
    {
        let c = raw(&v1);
        c.execute_batch(include_str!("../../spec/migrations/0001_init.sql")).unwrap();
        c.execute("INSERT INTO meta (key, value) VALUES ('schema_version', '1'), ('device_id', 'me')", []).unwrap();
        c.execute_batch("CREATE TRIGGER no_bump BEFORE UPDATE ON meta BEGIN SELECT RAISE(ABORT, 'no bump'); END;").unwrap();
    }
    assert!(Store::open(&v1, "me").is_err());
    let c = raw(&v1);
    assert_eq!(version(&c), "1");
    let peers: bool = c
        .query_row("SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE name='peers')", [], |r| r.get(0))
        .unwrap();
    assert!(!peers, "migration 0002 was rolled back");
    let _ = std::fs::remove_dir_all(&dir);
}
