//! Pure reducer: fold events in total order into timer state. No I/O, no clock.

use std::collections::HashMap;

use crate::types::*;

/// Folded state: all blocks plus the current (running or paused) block.
#[derive(Clone, Debug)]
pub struct State {
    config: Config,
    blocks: HashMap<String, Block>,
    initial_planned: HashMap<String, i64>,
    current: Option<String>,
    /// Block ids in the order they ended.
    ended_order: Vec<String>,
    /// Block ids touched since the last [`State::take_dirty`].
    dirty: Vec<String>,
    /// Largest `hlc_ms` applied so far; reads never use an earlier `now`.
    last_ms: i64,
}

/// Folds events, which must already be in total order (see [`sort_events`]).
pub fn fold(events_sorted: &[Event], config: Config) -> State {
    let mut s = State::new(config);
    for e in events_sorted {
        s.apply(e);
    }
    s
}

impl State {
    pub fn new(config: Config) -> State {
        State {
            config,
            blocks: HashMap::new(),
            initial_planned: HashMap::new(),
            current: None,
            ended_order: Vec::new(),
            dirty: Vec::new(),
            last_ms: i64::MIN,
        }
    }

    /// Applies the next event in total order. Events that do not apply are ignored.
    pub fn apply(&mut self, ev: &Event) {
        let t = ev.hlc_ms;
        self.last_ms = self.last_ms.max(t);
        self.settle(t);
        let Some(p) = ev.parse_payload() else { return };
        match p {
            Payload::Started { block_id, kind, planned_ms, label, project } => {
                if self.blocks.contains_key(&block_id) {
                    return;
                }
                if let Some(cur) = self.current.clone() {
                    self.end(&cur, t, Outcome::Abandoned);
                }
                self.initial_planned.insert(block_id.clone(), planned_ms);
                self.blocks.insert(
                    block_id.clone(),
                    Block {
                        id: block_id.clone(),
                        kind,
                        label,
                        project,
                        source: ev.source.clone(),
                        device_id: ev.device_id.clone(),
                        started_ms: t,
                        planned_ms,
                        elapsed_ms: 0,
                        phase: Phase::Running,
                        phase_since_ms: t,
                        outcome: None,
                        ended_ms: None,
                    },
                );
                self.current = Some(block_id.clone());
                self.dirty.push(block_id);
            }
            Payload::Paused { block_id } => {
                if let Some(b) = self.current_block_mut(&block_id) {
                    if b.phase == Phase::Running {
                        b.elapsed_ms += t - b.phase_since_ms;
                        b.phase = Phase::Paused;
                        b.phase_since_ms = t;
                        self.dirty.push(block_id);
                    }
                }
            }
            Payload::Resumed { block_id } => {
                if let Some(b) = self.current_block_mut(&block_id) {
                    if b.phase == Phase::Paused {
                        b.phase = Phase::Running;
                        b.phase_since_ms = t;
                        self.dirty.push(block_id);
                    }
                }
            }
            Payload::Extended { block_id, add_ms } => {
                if let Some(b) = self.current_block_mut(&block_id) {
                    b.planned_ms += add_ms;
                    self.dirty.push(block_id);
                }
            }
            Payload::Skipped { block_id } => {
                if self.current.as_deref() == Some(&block_id) {
                    self.end(&block_id, t, Outcome::Skipped);
                }
            }
            Payload::Stopped { block_id } => {
                if self.current.as_deref() == Some(&block_id) {
                    self.end(&block_id, t, Outcome::Abandoned);
                }
            }
            Payload::Reset { block_id } => {
                let initial = self.initial_planned.get(&block_id).copied();
                if let (Some(b), Some(initial)) = (self.current_block_mut(&block_id), initial) {
                    b.planned_ms = initial;
                    b.elapsed_ms = 0;
                    b.phase = Phase::Running;
                    b.phase_since_ms = t;
                    self.dirty.push(block_id);
                }
            }
            Payload::Labeled { block_id, label, project } => {
                if let Some(b) = self.blocks.get_mut(&block_id) {
                    if let Some(l) = label {
                        b.label = l;
                    }
                    if let Some(p) = project {
                        b.project = p;
                    }
                    self.dirty.push(block_id);
                }
            }
        }
    }

    fn current_block_mut(&mut self, block_id: &str) -> Option<&mut Block> {
        if self.current.as_deref() != Some(block_id) {
            return None;
        }
        self.blocks.get_mut(block_id)
    }

    /// Rule 1: complete the running current block if its end time is `<= t`.
    fn settle(&mut self, t: i64) {
        let Some(id) = self.current.clone() else { return };
        if let Some(s) = self.blocks.get(&id).and_then(|b| b.settled_at(t)) {
            self.blocks.insert(id.clone(), s);
            self.current = None;
            self.ended_order.push(id.clone());
            self.dirty.push(id);
        }
    }

    fn end(&mut self, id: &str, t: i64, outcome: Outcome) {
        let b = self.blocks.get_mut(id).expect("current block exists");
        if b.phase == Phase::Running {
            b.elapsed_ms += t - b.phase_since_ms;
        }
        b.outcome = Some(outcome);
        b.ended_ms = Some(t);
        b.phase = Phase::Ended;
        self.current = None;
        self.ended_order.push(id.to_string());
        self.dirty.push(id.to_string());
    }

    /// Ids of blocks changed since the last call (may repeat), cleared.
    pub fn take_dirty(&mut self) -> Vec<String> {
        std::mem::take(&mut self.dirty)
    }

    pub fn block(&self, id: &str) -> Option<&Block> {
        self.blocks.get(id)
    }

    /// Id of the running or paused block, before settling at any `now`.
    pub fn current_id(&self) -> Option<&str> {
        self.current.as_deref()
    }

    /// All blocks (not settled at any `now`), ordered by `(started_ms, id)`.
    pub fn blocks_sorted(&self) -> Vec<Block> {
        let mut v: Vec<Block> = self.blocks.values().cloned().collect();
        v.sort_by(|a, b| (a.started_ms, &a.id).cmp(&(b.started_ms, &b.id)));
        v
    }

    /// Reads state at `now`: settles once more, returns the timer and all blocks ordered by `(started_ms, id)`.
    pub fn at(&self, now_ms: i64) -> (TimerView, Vec<Block>) {
        let now_ms = now_ms.max(self.last_ms);
        let mut blocks = self.blocks_sorted();
        let cur = self.current.as_ref().and_then(|id| self.blocks.get(id));
        let settled = cur.and_then(|b| b.settled_at(now_ms));
        if let Some(s) = &settled {
            if let Some(slot) = blocks.iter_mut().find(|b| b.id == s.id) {
                *slot = s.clone();
            }
        }
        let next_kind = self.next_kind(settled.as_ref());
        let view = match (cur, &settled) {
            (Some(b), None) => TimerView {
                status: if b.phase == Phase::Running { TimerStatus::Running } else { TimerStatus::Paused },
                block_id: Some(b.id.clone()),
                kind: Some(b.kind),
                remaining_ms: Some(match b.phase {
                    Phase::Running => b.planned_ms - b.elapsed_ms - (now_ms - b.phase_since_ms),
                    _ => b.planned_ms - b.elapsed_ms,
                }),
                next_kind,
            },
            _ => TimerView { status: TimerStatus::Idle, block_id: None, kind: None, remaining_ms: None, next_kind },
        };
        (view, blocks)
    }

    /// Cycle rule: suggested kind after the most recently ended block (`just_ended` counts as the latest).
    fn next_kind(&self, just_ended: Option<&Block>) -> Kind {
        let mut newest_first = just_ended
            .into_iter()
            .chain(self.ended_order.iter().rev().filter_map(|id| self.blocks.get(id)));
        let Some(last) = newest_first.next() else { return Kind::Focus };
        if last.kind != Kind::Focus || last.outcome != Some(Outcome::Completed) {
            return Kind::Focus;
        }
        let mut n = 1u32;
        for b in newest_first {
            match (b.kind, b.outcome) {
                (Kind::LongBreak, _) => break,
                (Kind::Focus, Some(Outcome::Completed)) => n += 1,
                _ => {}
            }
        }
        if n >= self.config.long_break_every {
            Kind::LongBreak
        } else {
            Kind::ShortBreak
        }
    }
}
