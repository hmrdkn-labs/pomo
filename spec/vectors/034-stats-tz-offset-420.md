# 034 — day arithmetic with tz_offset_min 420

Day = floor((started_ms + 420 * 60000) / 86400000), 420 min = UTC+07:00.

| started_ms (UTC) | local (+07:00) | day | counted |
| --- | --- | --- | --- |
| 15:00:00Z | 22:00, 01-15 | 2026-01-15 | 200000 (skipped at +200000) |
| 18:00:00Z | 01:00, 01-16 | 2026-01-16 | 600000 (completed) |
| 20:00:00Z | 03:00, 01-16 | 2026-01-16 | 100000 (skipped at +100000) |

`focus_ms_by_day` = {2026-01-15: 200000, 2026-01-16: 700000}.

At `tz_offset_min 0` all three start times fall on 2026-01-15:
{2026-01-15: 200000 + 600000 + 100000 = 900000}.

Streak at `now = 21:00:00Z`: local day 2026-01-16 has one completed focus block,
local 2026-01-15 has only a skipped one → `streak_days` 1.
