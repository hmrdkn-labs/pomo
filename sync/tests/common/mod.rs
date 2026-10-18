#![allow(dead_code)]
use pomo_core::*;
use pomo_sync::{SyncNode, SyncOptions};
use std::time::{Duration, Instant};
use tempfile::TempDir;

pub struct T {
    pub node: SyncNode,
    _dir: TempDir,
}

impl std::ops::Deref for T {
    type Target = SyncNode;
    fn deref(&self) -> &SyncNode {
        &self.node
    }
}

pub async fn node() -> T {
    node_with(SyncOptions::local()).await
}

pub async fn node_with(opts: SyncOptions) -> T {
    let dir = tempfile::tempdir().unwrap();
    let node = SyncNode::open(dir.path().join("pomo.db"), opts).await.unwrap();
    T { node, _dir: dir }
}

/// Pairs both ways without a handshake.
pub fn trust(a: &T, b: &T) {
    a.trust_device(b.device_id(), "b").unwrap();
    b.trust_device(a.device_id(), "a").unwrap();
}

pub const T0: i64 = 1_700_000_000_000;

pub fn start(node: &SyncNode, at: i64) -> Event {
    cmd(node, CommandBody::Start { kind: Kind::Focus, planned_ms: 25 * 60_000, label: None, project: None }, at)
        .expect("start is always valid")
}

pub fn cmd(node: &SyncNode, body: CommandBody, at: i64) -> Option<Event> {
    node.apply(Command { body, command_key: None }, Source::User, at).ok()
}

pub fn ids(node: &SyncNode) -> Vec<String> {
    node.store().lock().unwrap().events().unwrap().into_iter().map(|e| e.id).collect()
}

pub fn count(node: &SyncNode) -> usize {
    ids(node).len()
}

/// Projection table == fold of the log.
pub fn assert_consistent(node: &SyncNode) {
    let store = node.store().lock().unwrap();
    let mut events = store.events().unwrap();
    sort_events(&mut events);
    let folded = fold(&events, Config::default()).blocks_sorted();
    let mut table = store.projected_blocks(Range::ALL).unwrap();
    table.sort_by(|a, b| (a.started_ms, &a.id).cmp(&(b.started_ms, &b.id)));
    assert_eq!(table, folded);
}

pub async fn eventually(what: &str, within: Duration, mut f: impl FnMut() -> bool) {
    let t = Instant::now();
    while !f() {
        assert!(t.elapsed() < within, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}
