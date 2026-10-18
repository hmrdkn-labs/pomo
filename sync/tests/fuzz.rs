mod common;
use common::*;
use pomo_core::*;
use rand::rngs::StdRng;
use rand::seq::SliceRandom;
use rand::{Rng, SeedableRng};

fn random_command(rng: &mut StdRng) -> CommandBody {
    match rng.gen_range(0..8) {
        0 | 1 => CommandBody::Start {
            kind: [Kind::Focus, Kind::ShortBreak, Kind::LongBreak][rng.gen_range(0..3)],
            planned_ms: rng.gen_range(1..40) * 60_000,
            label: rng.gen_bool(0.5).then(|| format!("l{}", rng.gen_range(0..5))),
            project: None,
        },
        2 => CommandBody::Pause,
        3 => CommandBody::Resume,
        4 => CommandBody::Extend { add_ms: rng.gen_range(1..10) * 60_000 },
        5 => CommandBody::Skip,
        6 => CommandBody::Stop,
        _ => CommandBody::Reset,
    }
}

#[tokio::test]
async fn random_logs_and_topologies_converge_to_the_core_fold() {
    for seed in 0..4u64 {
        let mut rng = StdRng::seed_from_u64(seed);
        let nodes = [node().await, node().await, node().await];
        // Connected topology on 3 nodes: a random path (2 edges) or the triangle.
        let mut edges: Vec<(usize, usize)> = vec![(0, 1), (1, 2), (0, 2)];
        edges.shuffle(&mut rng);
        edges.truncate(if rng.gen_bool(0.3) { 3 } else { 2 });
        for &(x, y) in &edges {
            let ticket = nodes[x].pairing_ticket("n").await.unwrap();
            nodes[y].pair(&ticket, "n").await.unwrap();
        }
        let mut clock = T0;
        for _ in 0..rng.gen_range(20..60) {
            clock += rng.gen_range(0..90_000);
            let i = rng.gen_range(0..3);
            cmd(&nodes[i], random_command(&mut rng), clock);
            if rng.gen_bool(0.1) {
                let &(x, y) = edges.choose(&mut rng).unwrap();
                nodes[x].sync_with(nodes[y].device_id()).await.unwrap();
            }
        }
        for _ in 0..3 {
            edges.shuffle(&mut rng);
            for &(x, y) in &edges {
                nodes[x].sync_with(nodes[y].device_id()).await.unwrap();
            }
        }
        let mut all: Vec<Event> = Vec::new();
        for n in &nodes {
            all.extend(n.store().lock().unwrap().events().unwrap());
        }
        all.sort_by(|a, b| a.id.cmp(&b.id));
        all.dedup_by(|a, b| a.id == b.id);
        sort_events(&mut all);
        let now = clock + 10_000_000;
        let (timer, blocks) = fold(&all, Config::default()).at(now);
        for n in &nodes {
            assert_eq!(count(n), all.len(), "seed {seed}");
            let store = n.store().lock().unwrap();
            assert_eq!(store.events().unwrap(), all, "seed {seed}");
            assert_eq!(store.timer(now), timer, "seed {seed}");
            let mut got = store.blocks(Range::ALL, now).unwrap();
            got.sort_by(|a, b| (a.started_ms, &a.id).cmp(&(b.started_ms, &b.id)));
            assert_eq!(got, blocks, "seed {seed}");
            drop(store);
            assert_consistent(n);
        }
    }
}
