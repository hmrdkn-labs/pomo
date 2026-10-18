use super::*;
use futures::executor::block_on;
use std::sync::mpsc as std_mpsc;
use std::time::Duration;

const MIN: i64 = 60_000;

fn open(dir: &tempfile::TempDir, name: &str) -> Arc<PomoCore> {
    PomoCore::open(dir.path().display().to_string(), name.into(), CoreNetwork::Local).unwrap()
}

struct Channel(Mutex<std_mpsc::Sender<CoreEvent>>);

impl PomoListener for Channel {
    fn on_event(&self, event: CoreEvent) {
        let _ = self.0.lock().unwrap().send(event);
    }
}

fn listen(core: &PomoCore) -> std_mpsc::Receiver<CoreEvent> {
    let (tx, rx) = std_mpsc::channel();
    core.set_listener(Some(Arc::new(Channel(Mutex::new(tx)))));
    rx
}

fn focus(core: &PomoCore, label: Option<&str>) -> CoreCommandResult {
    core.start(CoreKind::Focus, 25 * MIN, label.map(Into::into), None).unwrap()
}

#[test]
fn commands_drive_the_timer_and_history() {
    let dir = tempfile::tempdir().unwrap();
    let core = open(&dir, "phone");
    assert_eq!(core.status(0).unwrap().timer.status, CoreTimerStatus::Idle);

    let r = focus(&core, Some("write"));
    assert_eq!(r.event.event_type, "timer.started");
    assert_eq!(r.timer.status, CoreTimerStatus::Running);
    let block = r.timer.block.unwrap();
    assert_eq!((block.kind, block.planned_ms, block.label.as_deref()), (CoreKind::Focus, 25 * MIN, Some("write")));
    assert_eq!(block.source, "user");
    assert!(r.timer.remaining_ms.unwrap() > 24 * MIN);

    assert_eq!(core.pause().unwrap().timer.status, CoreTimerStatus::Paused);
    assert_eq!(core.resume().unwrap().timer.status, CoreTimerStatus::Running);
    let t = core.extend(5 * MIN).unwrap().timer;
    assert_eq!(t.block.as_ref().unwrap().planned_ms, 30 * MIN);
    assert!(t.remaining_ms.unwrap() > 29 * MIN);
    let t = core.reset().unwrap().timer;
    assert_eq!(t.block.as_ref().unwrap().planned_ms, 25 * MIN);
    core.label(None, Some("review".into())).unwrap();
    assert_eq!(core.timer().unwrap().block.unwrap().label.as_deref(), Some("review"));

    let t = core.skip().unwrap().timer;
    assert_eq!((t.status, t.block, t.remaining_ms), (CoreTimerStatus::Idle, None, None));

    let blocks = core.blocks(None, None, None, None).unwrap();
    assert_eq!(blocks.len(), 1);
    assert_eq!(blocks[0].outcome, Some(CoreOutcome::Skipped));
    assert_eq!(blocks[0].phase, CorePhase::Ended);
    assert_eq!(blocks[0].label.as_deref(), Some("review"));
    assert!(core.blocks(None, None, Some(CoreKind::ShortBreak), None).unwrap().is_empty());
}

#[test]
fn invalid_commands_map_to_typed_errors_and_write_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let core = open(&dir, "phone");
    assert!(matches!(core.pause(), Err(CoreError::InvalidState { .. })));
    assert!(matches!(core.skip(), Err(CoreError::InvalidState { .. })));
    assert!(matches!(core.start(CoreKind::Focus, 0, None, None), Err(CoreError::InvalidArgument { .. })));
    assert!(matches!(core.label(Some("nope".into()), Some("x".into())), Err(CoreError::NotFound { .. })));
    assert!(matches!(
        core.send(CoreCommand::Pause, Some("robot".into()), None),
        Err(CoreError::InvalidArgument { .. })
    ));
    assert!(matches!(core.status(5000), Err(CoreError::InvalidArgument { .. })));
    assert!(core.blocks(None, None, None, Some(0)).is_err());
    assert_eq!(core.store().version_vector().unwrap().values().sum::<u64>(), 0);
}

#[test]
fn a_reused_command_key_replays_without_writing_or_notifying() {
    let dir = tempfile::tempdir().unwrap();
    let core = open(&dir, "phone");
    let rx = listen(&core);
    let start = CoreCommand::Start { kind: CoreKind::Focus, planned_ms: 25 * MIN, label: None, project: None };
    let first = core.send(start.clone(), Some("agent:claude".into()), Some("k1".into())).unwrap();
    let again = core.send(start, Some("agent:claude".into()), Some("k1".into())).unwrap();
    assert!(!first.replayed && again.replayed);
    assert_eq!(first.event.id, again.event.id);
    assert_eq!(first.timer.block.as_ref().unwrap().source, "agent:claude");
    assert_eq!(core.blocks(None, None, None, None).unwrap().len(), 1);
    assert_eq!(rx.recv_timeout(Duration::from_secs(5)).unwrap().id, first.event.id);
    assert!(rx.recv_timeout(Duration::from_millis(300)).is_err(), "replay must not notify");
}

#[test]
fn listener_sees_local_events_in_order_and_can_be_removed() {
    let dir = tempfile::tempdir().unwrap();
    let core = open(&dir, "phone");
    let rx = listen(&core);
    focus(&core, None);
    core.pause().unwrap();
    let types: Vec<String> = (0..2).map(|_| rx.recv_timeout(Duration::from_secs(5)).unwrap().event_type).collect();
    assert_eq!(types, ["timer.started", "timer.paused"]);
    core.set_listener(None);
    core.resume().unwrap();
    assert!(rx.recv_timeout(Duration::from_millis(300)).is_err());
}

#[test]
fn stats_group_focus_time_like_the_api() {
    let dir = tempfile::tempdir().unwrap();
    let core = open(&dir, "phone");
    for label in [Some("a"), Some("a"), Some("b"), None] {
        focus(&core, label);
        core.skip().unwrap();
    }
    // Skipped blocks run for about 0 ms, so only grouping, keys and ordering are checked here.
    let by_label = core.stats(None, None, 0, CoreGroupBy::Label).unwrap();
    let keys: Vec<&str> = by_label.groups.iter().map(|g| g.key.as_str()).collect();
    assert_eq!(keys.len(), 3);
    assert!(keys.contains(&"") && keys.contains(&"a") && keys.contains(&"b"));
    assert!(by_label.groups.windows(2).all(|w| w[0].focus_ms >= w[1].focus_ms));
    let by_day = core.stats(None, None, 90, CoreGroupBy::Day).unwrap();
    assert_eq!(by_day.groups.len(), 1);
    let today = civil_day(now_ms(), 90);
    assert_eq!(by_day.groups[0].key, today);
    assert_eq!(by_day.tz_offset_min, 90);
    let status = core.status(90).unwrap();
    assert_eq!(status.today.focus_ms, by_day.focus_ms);
}

#[test]
fn civil_day_matches_known_dates() {
    assert_eq!(civil_day(0, 0), "1970-01-01");
    assert_eq!(civil_day(-1, 0), "1969-12-31");
    assert_eq!(civil_day(1_791_000_000_000, 0), "2026-10-03");
    assert_eq!(civil_day(1_791_000_000_000, -300), "2026-10-02");
}

#[test]
fn state_and_identity_survive_a_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let (id, block) = {
        let core = open(&dir, "phone");
        let block = focus(&core, Some("keep")).timer.block.unwrap();
        core.shutdown();
        (core.device_id(), block)
    };
    let core = open(&dir, "");
    assert_eq!(core.device_id(), id);
    assert_eq!(core.device_name(), "phone");
    let t = core.timer().unwrap();
    assert_eq!(t.status, CoreTimerStatus::Running);
    assert_eq!(t.block.unwrap().id, block.id);
}

#[test]
fn pairing_and_sync_share_one_timer_and_history() {
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (a, b) = (open(&da, "mac"), open(&db, "phone"));
    let rx_b = listen(&b);

    let ticket = block_on(a.clone().offer_pairing()).unwrap();
    assert!(ticket.ticket.starts_with("pomo-pair:"));
    let device = block_on(b.clone().join(ticket.ticket.clone())).unwrap();
    assert_eq!((device.device_id.as_str(), device.name.as_deref(), device.paired), (a.device_id().as_str(), Some("mac"), true));
    // Single use.
    assert!(matches!(block_on(b.clone().join(ticket.ticket)), Err(CoreError::PairingRejected { .. })));
    assert!(matches!(block_on(b.clone().join("nonsense".into())), Err(CoreError::BadTicket { .. })));

    let list = a.devices().unwrap();
    assert_eq!(list.name, "mac");
    assert_eq!(list.devices.len(), 1);
    assert_eq!((list.devices[0].name.as_deref(), list.devices[0].paired), (Some("phone"), true));

    // A starts a block; B pulls it.
    let started = focus(&a, Some("shared")).timer.block.unwrap();
    let results = block_on(b.clone().sync_now()).unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!((results[0].received, results[0].error.clone()), (1, None));
    let on_b = b.status(0).unwrap().timer;
    assert_eq!(on_b.status, CoreTimerStatus::Running);
    assert_eq!(on_b.block.as_ref().unwrap().id, started.id);
    assert_eq!(on_b.block.unwrap().device_id, a.device_id());
    assert_eq!(rx_b.recv_timeout(Duration::from_secs(5)).unwrap().event_type, "timer.started");

    // B pauses; A pulls it back through the session it dialed to A earlier.
    b.pause().unwrap();
    assert_eq!(rx_b.recv_timeout(Duration::from_secs(5)).unwrap().event_type, "timer.paused");
    block_on(b.clone().sync_now()).unwrap();
    assert_eq!(a.timer().unwrap().status, CoreTimerStatus::Paused);
    assert_eq!(a.blocks(None, None, None, None).unwrap(), {
        let mut v = b.blocks(None, None, None, None).unwrap();
        // elapsed of a live paused block is frozen, so equal on both
        v.sort_by(|x, y| x.id.cmp(&y.id));
        v
    });
}

#[test]
fn revoking_a_device_stops_sync() {
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (a, b) = (open(&da, "mac"), open(&db, "phone"));
    let ticket = block_on(a.clone().offer_pairing()).unwrap().ticket;
    let mac = block_on(b.clone().join(ticket)).unwrap();

    assert!(matches!(b.revoke(b.device_id()), Err(CoreError::InvalidArgument { .. })));
    assert!(matches!(b.revoke("unknown".into()), Err(CoreError::NotFound { .. })));
    let revoked = b.revoke(mac.device_id.clone()).unwrap();
    assert!(revoked.revoked && !revoked.paired);
    // Revoked peers are not dialed.
    assert!(block_on(b.clone().sync_now()).unwrap().is_empty());
    assert!(b.devices().unwrap().devices[0].revoked);
}
