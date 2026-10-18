# 035 — day arithmetic with tz_offset_min -300

-300 min = UTC-05:00.

| started_ms (UTC) | local (-05:00) | day | counted |
| --- | --- | --- | --- |
| 02:00:00Z | 21:00, 01-15 | 2026-01-15 | 400000 (skipped at +400000) |
| 06:00:00Z | 01:00, 01-16 | 2026-01-16 | 600000 (completed) |
| 07:00:00Z | 02:00, 01-16 | 2026-01-16 | 300000 (completed) |

`focus_ms_by_day` = {2026-01-15: 400000, 2026-01-16: 600000 + 300000 = 900000}.

At `tz_offset_min 0` all three fall on 2026-01-16:
{2026-01-16: 400000 + 600000 + 300000 = 1300000}.

Streak at `now = 07:10:00Z`: local day 2026-01-16 (02:10) has two completed focus
blocks, local 2026-01-15 has only a skipped one → `streak_days` 1.
