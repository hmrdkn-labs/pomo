# 037 — streak arithmetic

Completed focus days: 01-10, 01-11, 01-13, 01-14. 2026-01-12 has a skipped focus
block only, so it is not a streak day but does contribute 120000 ms of focus time.

- `now = 2026-01-14T10:00:00Z`: today 01-14 ✓, 01-13 ✓, 01-12 ✗ → 2.
- `now = 2026-01-15T12:00:00Z`: today 01-15 has no block, so the streak ends
  yesterday: 01-14 ✓, 01-13 ✓, 01-12 ✗ → 2.
- `now = 2026-01-16T12:00:00Z`: neither today 01-16 nor yesterday 01-15 has a
  completed focus block → 0 (a streak must end today or yesterday).

`focus_ms_by_day` = 600000 + 300000 + 120000 + 600000 + 600000 = 2220000 over the
five days, `completed_focus` = 4.
