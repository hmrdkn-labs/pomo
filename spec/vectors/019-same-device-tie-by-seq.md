# 019 — tie broken by seq

`seq 1` and `seq 2` from the same device carry identical `(hlc_ms, hlc_counter)`
= `(1700000100000, 0)`. The HLC issuing rule would never emit that pair (the second
event would take `counter + 1`), so this is a fold input rather than something a
Device produces; `events.md` still fixes the order of any such pair: after the two
HLC fields and `device_id` are equal, `seq` decides.

With `seq 1` first the pause applies at `t`, banks `t - phase_since_ms = 0` ms and
leaves the block paused with `remaining_ms = 300000 - 0`. With `seq 2` first the
pause would find no block and be ignored, leaving the block running.
