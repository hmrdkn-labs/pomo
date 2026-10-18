use pomo_core::*;
use rand::rngs::StdRng;
use rand::seq::SliceRandom;
use rand::{Rng, SeedableRng};
use serde_json::{json, Value};

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

/// Random event set over 3 devices with colliding timestamps and mostly-sensible block ids.
fn random_events(rng: &mut StdRng, n: usize) -> Vec<Event> {
    let devs = ["a", "b", "c"];
    let mut seqs = [0u64; 3];
    let mut started: Vec<String> = Vec::new();
    let mut t = 1_000_000i64;
    let mut out = Vec::new();
    for i in 0..n {
        let d = rng.gen_range(0..3);
        seqs[d] += 1;
        t += rng.gen_range(0..40_000);
        let ctr = rng.gen_range(0..3);
        let pick = |rng: &mut StdRng, started: &Vec<String>| -> String {
            if started.is_empty() || rng.gen_range(0..10) == 0 {
                "unknown".into()
            } else {
                started[rng.gen_range(0..started.len())].clone()
            }
        };
        let (ty, payload) = match rng.gen_range(0..9) {
            0..=2 => {
                let id = format!("blk{i}");
                started.push(id.clone());
                let kind = ["focus", "focus", "short_break", "long_break"][rng.gen_range(0..4)];
                ("timer.started", json!({"block_id": id, "kind": kind, "planned_ms": rng.gen_range(1..100_000), "label": "x"}))
            }
            3 => ("timer.paused", json!({"block_id": pick(rng, &started)})),
            4 => ("timer.resumed", json!({"block_id": pick(rng, &started)})),
            5 => ("timer.extended", json!({"block_id": pick(rng, &started), "add_ms": rng.gen_range(1..50_000)})),
            6 => ("timer.skipped", json!({"block_id": pick(rng, &started)})),
            7 => ("timer.reset", json!({"block_id": pick(rng, &started)})),
            _ => ("block.labeled", json!({"block_id": pick(rng, &started), "label": if rng.gen() { json!("l") } else { Value::Null }})),
        };
        out.push(ev(i as u32 + 1, devs[d], seqs[d], t, ctr, ty, payload));
    }
    out
}

#[test]
fn any_order_and_duplication_same_state_and_projection() {
    let mut rng = StdRng::seed_from_u64(7);
    for round in 0..40 {
        let events = random_events(&mut rng, 60);
        let mut sorted = events.clone();
        sort_events(&mut sorted);
        let want = fold(&sorted, Config::default());
        let mut results = Vec::new();
        for _ in 0..4 {
            let mut shuffled = events.clone();
            shuffled.extend(events.iter().take(20).cloned());
            shuffled.shuffle(&mut rng);
            let mut store = Store::open_in_memory("local").unwrap();
            // Random batch sizes exercise both the incremental and replay paths.
            let mut rest = &shuffled[..];
            while !rest.is_empty() {
                let k = rng.gen_range(1..=7).min(rest.len());
                store.ingest(&rest[..k]).unwrap();
                rest = &rest[k..];
            }
            assert_eq!(
                store.projected_blocks(Range::ALL).unwrap(),
                want.blocks_sorted(),
                "round {round}: projection != fold"
            );
            for now in [1_000_000, 2_000_000, 50_000_000] {
                assert_eq!(store.timer(now), want.at(now).0, "round {round} timer at {now}");
                assert_eq!(store.blocks(Range::ALL, now).unwrap(), want.at(now).1, "round {round} blocks at {now}");
            }
            let before = store.projected_blocks(Range::ALL).unwrap();
            store.rebuild_projections().unwrap();
            assert_eq!(before, store.projected_blocks(Range::ALL).unwrap());
            results.push(store.events().unwrap());
        }
        assert!(results.iter().all(|r| *r == sorted));
    }
}

#[test]
fn ingest_rejects_seq_conflict_and_is_idempotent() {
    let mut s = Store::open_in_memory("local").unwrap();
    let a = ev(1, "peer", 1, 10, 0, "timer.started", json!({"block_id":"b","kind":"focus","planned_ms":5}));
    let mut b = a.clone();
    b.id = "00000000-0000-4000-8000-000000000002".into();
    let r = s.ingest(&[a.clone(), a.clone(), b]).unwrap();
    assert_eq!((r.inserted, r.duplicates, r.conflicts.len()), (1, 1, 1));
    assert_eq!(s.events().unwrap(), vec![a]);
    assert_eq!(s.version_vector().unwrap()["peer"], 1);
}

#[test]
fn hlc_rule_and_seq_allocation() {
    let mut s = Store::open_in_memory("me").unwrap();
    let start = Command { body: CommandBody::Start { kind: Kind::Focus, planned_ms: 60_000, label: None, project: None }, command_key: None };
    let e1 = s.apply(start.clone(), Source::User, 1000).unwrap();
    assert_eq!((e1.seq, e1.hlc_ms, e1.hlc_counter), (1, 1000, 0));
    // clock not advancing, then going backwards
    let e2 = s.apply(start.clone(), Source::User, 1000).unwrap();
    assert_eq!((e2.seq, e2.hlc_ms, e2.hlc_counter), (2, 1000, 1));
    let e3 = s.apply(start.clone(), Source::User, 500).unwrap();
    assert_eq!((e3.seq, e3.hlc_ms, e3.hlc_counter), (3, 1000, 2));
    // seen remote event ahead of local clock
    s.ingest(&[ev(9, "peer", 1, 5000, 3, "x.unknown", json!({}))]).unwrap();
    let e4 = s.apply(start, Source::Agent("claude".into()), 2000).unwrap();
    assert_eq!((e4.hlc_ms, e4.hlc_counter), (5000, 4));
    assert_eq!(e4.source.to_string(), "agent:claude");
}

#[test]
fn commands_validate_and_are_idempotent() {
    let mut s = Store::open_in_memory("me").unwrap();
    let c = |body, key: &str| Command { body, command_key: Some(key.into()) };
    assert!(s.apply(c(CommandBody::Pause, "p0"), Source::User, 1).is_err());
    let start = c(CommandBody::Start { kind: Kind::Focus, planned_ms: 1000, label: None, project: None }, "s");
    let e = s.apply(start.clone(), Source::User, 10).unwrap();
    assert_eq!(s.apply(start, Source::User, 99).unwrap(), e);
    assert!(s.apply(c(CommandBody::Resume, "r"), Source::User, 20).is_err());
    s.apply(c(CommandBody::Pause, "p"), Source::User, 20).unwrap();
    assert!(s.apply(c(CommandBody::Pause, "p2"), Source::User, 30).is_err());
    // block completes unobserved: commands against it are invalid afterwards
    assert!(s.apply(c(CommandBody::Resume, "r2"), Source::User, 40).is_ok());
    assert!(s.apply(c(CommandBody::Stop, "x"), Source::User, 5000).is_err());
    assert_eq!(s.events().unwrap().len(), 3);
    let l = s
        .apply(c(CommandBody::Label { block_id: None, label: Some("done".into()), project: Some(Some("p".into())) }, "l"), Source::User, 6000)
        .unwrap();
    assert_eq!(l.ty, "block.labeled");
    let b = s.blocks(Range::ALL, 6000).unwrap();
    assert_eq!((b[0].label.as_deref(), b[0].project.as_deref(), b[0].outcome), (Some("done"), Some("p"), Some(Outcome::Completed)));
}

#[test]
fn two_stores_converge_through_version_vectors() {
    let mut a = Store::open_in_memory("a").unwrap();
    let mut b = Store::open_in_memory("b").unwrap();
    let start = |k: &str| Command { body: CommandBody::Start { kind: Kind::Focus, planned_ms: 60_000, label: None, project: None }, command_key: Some(k.into()) };
    a.apply(start("1"), Source::User, 1000).unwrap();
    b.apply(start("1"), Source::User, 1000).unwrap();
    a.apply(Command { body: CommandBody::Pause, command_key: None }, Source::User, 2000).unwrap();
    let to_b = a.events_after(&b.version_vector().unwrap()).unwrap();
    let to_a = b.events_after(&a.version_vector().unwrap()).unwrap();
    b.ingest(&to_b).unwrap();
    a.ingest(&to_a).unwrap();
    assert_eq!(a.events().unwrap(), b.events().unwrap());
    assert_eq!(a.timer(3000), b.timer(3000));
    assert!(a.events_after(&b.version_vector().unwrap()).unwrap().is_empty());
}

#[test]
fn stats_streak_and_days() {
    let day = 86_400_000i64;
    let mut s = Store::open_in_memory("me").unwrap();
    let mut events = Vec::new();
    // completed focus on days 0,1,2 (offset 0), 10-minute blocks, plus a skipped one on day 2
    for (i, d) in [0i64, 1, 2].iter().enumerate() {
        events.push(ev(i as u32 + 1, "x", i as u64 + 1, d * day + 1000, 0, "timer.started", json!({"block_id": format!("b{i}"), "kind":"focus", "planned_ms": 600_000})));
    }
    events.push(ev(10, "x", 4, 2 * day + 700_000, 0, "timer.started", json!({"block_id":"s","kind":"focus","planned_ms":600_000})));
    events.push(ev(11, "x", 5, 2 * day + 760_000, 0, "timer.skipped", json!({"block_id":"s"})));
    s.ingest(&events).unwrap();
    let st = s.stats(Range::ALL, 0, 2 * day + 800_000).unwrap();
    assert_eq!(st.completed_focus, 3);
    assert_eq!(st.focus_ms_by_day["1970-01-03"], 600_000 + 60_000);
    assert_eq!(st.streak_days, 3);
    // yesterday still counts, two days ago does not
    assert_eq!(s.stats(Range::ALL, 0, 3 * day + 5).unwrap().streak_days, 3);
    assert_eq!(s.stats(Range::ALL, 0, 4 * day + 5).unwrap().streak_days, 0);
    // offset shifts the day boundary
    let st = s.stats(Range::ALL, -60, 2 * day + 800_000).unwrap();
    assert!(st.focus_ms_by_day.contains_key("1969-12-31"));
}

#[test]
fn error_variants_are_typed() {
    let mut s = Store::open_in_memory("me").unwrap();
    let cmd = |body| Command { body, command_key: None };
    assert!(matches!(s.apply(cmd(CommandBody::Pause), Source::User, 1), Err(Error::InvalidState(_))));
    let bad = CommandBody::Start { kind: Kind::Focus, planned_ms: 0, label: None, project: None };
    assert!(matches!(s.apply(cmd(bad), Source::User, 1), Err(Error::InvalidArgument(_))));
    assert!(matches!(s.apply(cmd(CommandBody::Extend { add_ms: -5 }), Source::User, 1), Err(Error::InvalidArgument(_))));
    let start = CommandBody::Start { kind: Kind::Focus, planned_ms: 1000, label: None, project: None };
    s.apply(cmd(start), Source::User, 2).unwrap();
    let unknown = CommandBody::Label { block_id: Some("nope".into()), label: Some("x".into()), project: None };
    assert!(matches!(s.apply(cmd(unknown), Source::User, 3), Err(Error::NotFound(_))));
}

#[test]
fn ingest_atomic_rejects_whole_call_on_conflict() {
    let mut s = Store::open_in_memory("me").unwrap();
    let started = |id, dev: &str, seq| ev(id, dev, seq, 1000 + id as i64, 0, "timer.started", json!({"block_id": format!("b{id}"), "kind":"focus", "planned_ms": 1000}));
    s.ingest(&[started(1, "peer", 1)]).unwrap();
    let before = s.events().unwrap();
    let blocks_before = s.projected_blocks(Range::ALL).unwrap();
    // (peer, 1) is stored under another id; the clean events around it must not be stored either.
    let frame = [started(2, "peer", 2), started(3, "peer", 1), started(4, "other", 1)];
    assert!(matches!(s.ingest_atomic(&frame), Err(Error::Conflict(_))));
    assert_eq!(s.events().unwrap(), before);
    assert_eq!(s.projected_blocks(Range::ALL).unwrap(), blocks_before);
    // A conflict between two events of the same call is also caught.
    assert!(matches!(s.ingest_atomic(&[started(5, "x", 1), started(6, "x", 1)]), Err(Error::Conflict(_))));
    assert_eq!(s.events().unwrap(), before);
    // The lenient variant stores the clean rest and reports the conflict.
    let r = s.ingest(&frame).unwrap();
    assert_eq!((r.inserted, r.conflicts.len()), (2, 1));
    // A clean call through the atomic variant works and is idempotent.
    let clean = [started(7, "peer", 3)];
    assert_eq!(s.ingest_atomic(&clean).unwrap().inserted, 1);
    assert_eq!(s.ingest_atomic(&clean).unwrap().duplicates, 1);
}

#[test]
fn devices_and_peer_addresses() {
    let mut s = Store::open_in_memory("me").unwrap();
    assert_eq!(s.device("peer").unwrap(), None);
    s.upsert_device("peer", "phone").unwrap();
    let d = s.device("peer").unwrap().unwrap();
    assert_eq!((d.name.as_deref(), d.paired, d.revoked), (Some("phone"), false, false));
    s.set_device_paired("peer", true).unwrap();
    s.upsert_device("peer", "phone 2").unwrap(); // renaming keeps trust
    s.set_device_revoked("peer", true).unwrap();
    let d = s.device("peer").unwrap().unwrap();
    assert_eq!((d.name.as_deref(), d.paired, d.revoked), (Some("phone 2"), true, true));
    s.set_device_revoked("peer", false).unwrap();
    assert!(!s.device("peer").unwrap().unwrap().revoked);
    // Unknown ids are recorded, e.g. to revoke before any event was seen.
    s.set_device_revoked("ghost", true).unwrap();
    assert!(s.device("ghost").unwrap().unwrap().revoked);
    let ids: Vec<String> = s.devices().unwrap().into_iter().map(|d| d.device_id).collect();
    assert_eq!(ids, ["ghost", "me", "peer"]);
    assert!(matches!(s.upsert_device("", "x"), Err(Error::InvalidArgument(_))));

    assert_eq!(s.peer_address("peer").unwrap(), None);
    s.set_peer_address("peer", "addr-1", 10).unwrap();
    s.set_peer_address("peer", "addr-2", 20).unwrap();
    assert_eq!(s.peer_address("peer").unwrap().as_deref(), Some("addr-2"));
}

#[test]
fn peers_and_trust_survive_reopen_and_v1_stores_migrate() {
    let dir = std::env::temp_dir().join(format!("pomo-core-migrate-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("pomo.db");
    let _ = std::fs::remove_file(&path);
    {
        let mut s = Store::open(&path, "me").unwrap();
        s.set_device_paired("peer", true).unwrap();
        s.set_peer_address("peer", "addr", 1).unwrap();
    }
    let s = Store::open(&path, "me").unwrap();
    assert!(s.device("peer").unwrap().unwrap().paired);
    assert_eq!(s.peer_address("peer").unwrap().as_deref(), Some("addr"));
    drop(s);

    // A store created by schema version 1 (no `peers` table) gains it on open.
    let old = dir.join("old.db");
    let _ = std::fs::remove_file(&old);
    {
        let c = rusqlite::Connection::open(&old).unwrap();
        c.execute_batch(include_str!("../../spec/migrations/0001_init.sql")).unwrap();
        c.execute("INSERT INTO meta (key, value) VALUES ('schema_version', '1'), ('device_id', 'me')", []).unwrap();
    }
    let mut s = Store::open(&old, "me").unwrap();
    s.set_peer_address("peer", "addr", 1).unwrap();
    assert_eq!(s.peer_address("peer").unwrap().as_deref(), Some("addr"));
    let _ = std::fs::remove_dir_all(&dir);
}
