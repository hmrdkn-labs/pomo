# 018 — tie broken by device_id

Both `timer.started` events carry `hlc_ms = 1700000000000`, `hlc_counter = 0`.
The total order is `(hlc_ms, hlc_counter, device_id, seq)` with strings compared by
byte order, so `"mac"` (0x6d…) sorts before `"phone"` (0x70…).

mac's start is applied first; phone's start then runs rule 2 at the same
`t = 1700000000000`: mac's block is running, so `elapsed_ms += t - phase_since_ms = 0`,
`outcome = abandoned`, `ended_ms = t`. Reverse the order and `b…001` would be the live
block instead, so the checks pin the tie-break.
