//! Statistics over blocks (spec/events.md, Statistics).

use std::collections::{BTreeMap, BTreeSet};

use crate::types::*;

const DAY_MS: i64 = 86_400_000;

/// Day number (days since 1970-01-01) of `ms` in a fixed offset.
fn day_number(ms: i64, tz_offset_min: i32) -> i64 {
    (ms + i64::from(tz_offset_min) * 60_000).div_euclid(DAY_MS)
}

/// `YYYY-MM-DD` for a day number (proleptic Gregorian, Hinnant's civil_from_days).
fn day_key(days: i64) -> String {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}")
}

/// Computes stats. `blocks` must be all blocks settled at `now_ms`; `range` filters by `started_ms`
/// for focus time and completed count, the streak always uses every block.
pub fn compute(blocks: &[Block], range: Range, tz_offset_min: i32, now_ms: i64) -> Stats {
    let mut by_day: BTreeMap<String, i64> = BTreeMap::new();
    let mut total = 0;
    let mut completed = 0;
    let mut streak_days_set: BTreeSet<i64> = BTreeSet::new();
    for b in blocks.iter().filter(|b| b.kind == Kind::Focus) {
        let day = day_number(b.started_ms, tz_offset_min);
        if b.outcome == Some(Outcome::Completed) {
            streak_days_set.insert(day);
        }
        if range.contains(b.started_ms) {
            *by_day.entry(day_key(day)).or_insert(0) += b.elapsed_ms;
            total += b.elapsed_ms;
            if b.outcome == Some(Outcome::Completed) {
                completed += 1;
            }
        }
    }
    let today = day_number(now_ms, tz_offset_min);
    let mut d = if streak_days_set.contains(&today) { today } else { today - 1 };
    let mut streak = 0;
    while streak_days_set.contains(&d) {
        streak += 1;
        d -= 1;
    }
    Stats { focus_ms_by_day: by_day, focus_ms_total: total, completed_focus: completed, streak_days: streak }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn day_keys() {
        assert_eq!(day_key(0), "1970-01-01");
        assert_eq!(day_key(-1), "1969-12-31");
        assert_eq!(day_key(19_782), "2024-02-29");
        assert_eq!(day_key(day_number(0, -60)), "1969-12-31");
        assert_eq!(day_key(day_number(DAY_MS - 1, 60)), "1970-01-02");
    }
}
