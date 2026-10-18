//! Runs every spec/vectors/*.json (see spec/vectors/FORMAT.md).

use std::fs;
use std::path::{Path, PathBuf};

use pomo_core::{Command, Config, Event, Range, Source, Store};
use serde_json::Value;

fn vectors_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../spec/vectors")
}

fn lcg_shuffle<T>(v: &mut [T]) {
    let mut s: u64 = 0x9E37_79B9_7F4A_7C15;
    for i in (1..v.len()).rev() {
        s = s.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        v.swap(i, ((s >> 33) as usize) % (i + 1));
    }
}

/// Compares keys present in `want` against `got`; `skip_null` keys with null in `want` are not checked.
fn check_fields(ctx: &str, want: &Value, got: &Value, skip_null: &[&str], errs: &mut Vec<String>) {
    let Some(wm) = want.as_object() else { return };
    for (k, w) in wm {
        if w.is_null() && skip_null.contains(&k.as_str()) {
            continue;
        }
        let g = got.get(k).unwrap_or(&Value::Null);
        if g != w {
            errs.push(format!("{ctx} field `{k}`: expected {w}, got {g}"));
        }
    }
}

/// Runs the checks; returns the observed results (for cross-order comparison).
fn run_checks(file: &str, v: &Value, events: &[Event], config: Config, errs: &mut Vec<String>, tag: &str) -> Vec<String> {
    let mut store = Store::open_in_memory_with("vector-runner", config).unwrap();
    for e in events {
        store.ingest(std::slice::from_ref(e)).unwrap();
        store.ingest(std::slice::from_ref(e)).unwrap();
    }
    let mut observed = Vec::new();
    let checks = v["checks"].as_array().cloned().unwrap_or_default();
    for (i, c) in checks.iter().enumerate() {
        let now = c["now_ms"].as_i64().unwrap_or_else(|| panic!("{file} check {i}: now_ms missing"));
        let ctx = format!("{file} [{tag}] check {i} (now_ms={now})");
        let timer = serde_json::to_value(store.timer(now)).unwrap();
        let blocks = serde_json::to_value(store.blocks(Range::ALL, now).unwrap()).unwrap();
        observed.push(format!("{timer}{blocks}"));
        if let Some(t) = c.get("timer") {
            check_fields(&format!("{ctx} timer"), t, &timer, &[], errs);
            for k in ["block_id", "remaining_ms"] {
                if t.get(k).is_none() && timer.get(k).is_some() {
                    errs.push(format!("{ctx} timer field `{k}`: expected absent, got {}", timer[k]));
                }
            }
        }
        if let Some(wb) = c.get("blocks").and_then(Value::as_array) {
            let gb = blocks.as_array().unwrap();
            if wb.len() != gb.len() {
                errs.push(format!("{ctx} blocks: expected {} blocks, got {}", wb.len(), gb.len()));
            }
            for (j, (w, g)) in wb.iter().zip(gb).enumerate() {
                check_fields(&format!("{ctx} blocks[{j}]"), w, g, &["elapsed_ms"], errs);
            }
        }
        if let Some(s) = c.get("stats") {
            let tz = s["tz_offset_min"].as_i64().unwrap_or(0) as i32;
            let got = serde_json::to_value(store.stats(Range::ALL, tz, now).unwrap()).unwrap();
            observed.push(got.to_string());
            let mut want = s.clone();
            want.as_object_mut().unwrap().remove("tz_offset_min");
            check_fields(&format!("{ctx} stats"), &want, &got, &[], errs);
            if let Some(w) = s.get("focus_ms_by_day") {
                if *w != got["focus_ms_by_day"] {
                    errs.push(format!(
                        "{ctx} stats field `focus_ms_by_day`: expected {w}, got {}",
                        got["focus_ms_by_day"]
                    ));
                }
            }
        }
    }
    observed
}

fn run_events_vector(file: &str, v: &Value, errs: &mut Vec<String>) {
    let events: Vec<Event> = match serde_json::from_value(v["events"].clone()) {
        Ok(e) => e,
        Err(e) => {
            errs.push(format!("{file} field `events`: {e}"));
            return;
        }
    };
    let config: Config = v.get("config").map_or(Config::default(), |c| {
        serde_json::from_value(c.clone()).unwrap_or_else(|e| panic!("{file} field `config`: {e}"))
    });
    let base = run_checks(file, v, &events, config, errs, "listed order");
    if v["order_independent"].as_bool() == Some(true) {
        let mut rev = events.clone();
        rev.reverse();
        let mut shuf = events.clone();
        lcg_shuffle(&mut shuf);
        for (tag, evs) in [("reversed", rev), ("shuffled", shuf)] {
            let other = run_checks(file, v, &evs, config, errs, tag);
            if other != base {
                errs.push(format!("{file} [{tag}]: results differ from listed order"));
            }
        }
    }
}

fn run_commands_vector(file: &str, v: &Value, errs: &mut Vec<String>) {
    let dev = v["device_id"].as_str().unwrap_or("dev");
    let mut store = Store::open_in_memory(dev).unwrap();
    let mut results: Vec<Option<Event>> = Vec::new();
    for (i, s) in v["steps"].as_array().cloned().unwrap_or_default().iter().enumerate() {
        let ctx = format!("{file} step {i}");
        let now = s["now_ms"].as_i64().unwrap_or_else(|| panic!("{ctx}: now_ms missing"));
        let cmd: Command = match serde_json::from_value(s["command"].clone()) {
            Ok(c) => c,
            Err(e) => {
                errs.push(format!("{ctx} field `command`: {e}"));
                results.push(None);
                continue;
            }
        };
        let r = store.apply(cmd, Source::User, now);
        let want = s["expect"].as_str().unwrap_or("ok");
        match (&r, want) {
            (Ok(_), "ok") | (Err(_), "error") => {}
            _ => errs.push(format!("{ctx} field `expect`: expected {want}, got {:?}", r.as_ref().map(|e| &e.ty))),
        }
        if let (Some(j), Ok(e)) = (s["same_events_as_step"].as_u64(), &r) {
            match results.get(j as usize) {
                Some(Some(prev)) if prev == e => {}
                _ => errs.push(format!("{ctx} field `same_events_as_step`: event differs from step {j}")),
            }
        }
        results.push(r.ok());
    }
    if let Some(n) = v["final_event_count"].as_u64() {
        let got = store.events().unwrap().len() as u64;
        if got != n {
            errs.push(format!("{file} field `final_event_count`: expected {n}, got {got}"));
        }
    }
}

#[test]
fn spec_vectors() {
    let mut files: Vec<PathBuf> = match fs::read_dir(vectors_dir()) {
        Ok(d) => d.filter_map(|e| e.ok().map(|e| e.path())).collect(),
        Err(_) => Vec::new(),
    };
    files.retain(|p| p.extension().is_some_and(|x| x == "json"));
    files.sort();
    let mut errs = Vec::new();
    for p in &files {
        let name = p.file_name().unwrap().to_string_lossy().to_string();
        let v: Value = match fs::read_to_string(p).map_err(|e| e.to_string()).and_then(|s| serde_json::from_str(&s).map_err(|e| e.to_string())) {
            Ok(v) => v,
            Err(e) => {
                errs.push(format!("{name}: cannot load: {e}"));
                continue;
            }
        };
        if v.get("steps").is_some() {
            run_commands_vector(&name, &v, &mut errs);
        } else {
            run_events_vector(&name, &v, &mut errs);
        }
    }
    eprintln!("ran {} vector files", files.len());
    assert!(errs.is_empty(), "{} vector failure(s):\n{}", errs.len(), errs.join("\n"));
}
