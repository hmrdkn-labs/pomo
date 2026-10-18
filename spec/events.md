# Events and timer rules (spec v1)

This file is the contract. Every Core build, in any language, must produce the same results from the same events. Terms follow `../CONTEXT.md`. Test vectors in `vectors/` are normative where this text is silent; if they disagree with this text, fix the text.

All times are integer milliseconds since the Unix epoch (UTC). All durations are integer milliseconds.

## Event envelope

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string | UUID, lowercase hyphenated. Globally unique; the idempotency key for ingestion. |
| `device_id` | string | Identity of the issuing Device. Opaque non-empty string (later: the iroh public key in hex). |
| `seq` | integer >= 1 | Per-Device counter, increasing by 1 with no gaps. `(device_id, seq)` is unique. |
| `hlc_ms` | integer | Hybrid logical clock wall part. |
| `hlc_counter` | integer >= 0 | Hybrid logical clock logical part. |
| `type` | string | One of the types below. |
| `payload` | object | Type-specific, below. Unknown extra keys are preserved and ignored. |
| `source` | string | `user` or `agent:<name>`. |
| `command_key` | string or null | Idempotency key of the Command that produced the event. |

### Total order

Events are ordered by the tuple `(hlc_ms, hlc_counter, device_id, seq)`, compared field by field (strings by byte order). This order is total and the same on every Device. State is the fold of the reducer over the events in this order. A Device that receives an event that sorts before events it has already seen must produce the same state as if it had received all events in order (replay from the insertion point, or rebuild).

### HLC rule for issuing

When a Device issues an event at wall time `now`: let `last` be the greatest `(hlc_ms, hlc_counter)` it has stored or seen. If `now > last.hlc_ms`, use `(now, 0)`. Otherwise use `(last.hlc_ms, last.hlc_counter + 1)`. The event's effective time in the rules below is `hlc_ms`.

### Ingestion

Ingesting an event whose `id` is already stored is a no-op. Ingesting an event whose `(device_id, seq)` exists with a different `id` is an error (corrupt peer); reject it and do not store it.

## Event types

`block_id` is a UUID string chosen by the issuer of `timer.started` and carried by every later event about that block.

| Type | Payload | Meaning |
| --- | --- | --- |
| `timer.started` | `block_id`, `kind` (`focus` \| `short_break` \| `long_break`), `planned_ms` (>0), `label` (string, optional), `project` (string, optional) | Starts a new block, running from `hlc_ms`. |
| `timer.paused` | `block_id` | Pauses the block. |
| `timer.resumed` | `block_id` | Resumes a paused block. |
| `timer.extended` | `block_id`, `add_ms` (>0) | Adds time to the block. |
| `timer.skipped` | `block_id` | Ends the block early with outcome `skipped`. |
| `timer.stopped` | `block_id` | Ends the block early with outcome `abandoned`. |
| `timer.reset` | `block_id` | Restarts the block from its original `planned_ms`, running from `hlc_ms`. Discards extensions and elapsed time. |
| `block.labeled` | `block_id`, `label` (string or null), `project` (string or null, optional) | Sets the label (and project when the key is present) of any block, current or past. A present `null` clears. |

## Reducer rules

State: a map of blocks plus `current` (the id of the block that is running or paused, or none).

A block has: `id`, `kind`, `label`, `project`, `source` (of its `timer.started`), `device_id` (of its `timer.started`), `started_ms`, `planned_ms`, `elapsed_ms`, `phase` (`running` \| `paused` \| `ended`), `phase_since_ms`, `outcome` (`completed` \| `skipped` \| `abandoned` \| none while live), `ended_ms`.

Define for a live block: `remaining_ms = planned_ms - elapsed_ms` at the moment `phase_since_ms` when running. A running block's end time is `ends_ms = phase_since_ms + remaining_ms`.

Process events in total order. Let `t = hlc_ms` of the event.

1. **Settle first.** Before applying any event, if `current` is a running block with `ends_ms <= t`, end it: `outcome = completed`, `elapsed_ms = planned_ms`, `ended_ms = ends_ms`, `phase = ended`, `current = none`. (A block completes at its end time even if nothing observed it.)
2. `timer.started`: if `current` is live (running or paused) it is ended with outcome `abandoned`: for a running block `elapsed_ms += t - phase_since_ms`; for a paused block elapsed is unchanged; `ended_ms = t`. Then create the new block: `phase = running`, `started_ms = phase_since_ms = t`, `elapsed_ms = 0`. A `timer.started` for a `block_id` that already exists is ignored.
3. `timer.paused`: applies only if `block_id == current` and it is running. `elapsed_ms += t - phase_since_ms`; `phase = paused`; `phase_since_ms = t`.
4. `timer.resumed`: applies only if `block_id == current` and it is paused. `phase = running`; `phase_since_ms = t`.
5. `timer.extended`: applies only if `block_id == current`. `planned_ms += add_ms`. Running or paused.
6. `timer.skipped` / `timer.stopped`: apply only if `block_id == current`. For a running block `elapsed_ms += t - phase_since_ms`. Set `outcome` to `skipped` / `abandoned`, `ended_ms = t`, `phase = ended`, `current = none`.
7. `timer.reset`: applies only if `block_id == current`. `planned_ms` returns to the original value from `timer.started`; `elapsed_ms = 0`; `phase = running`; `phase_since_ms = t`; `started_ms` is unchanged.
8. `block.labeled`: applies to any known block, including ended ones; unknown `block_id` is ignored. Last event in total order wins per field.

An event that does not apply is ignored. It stays in the log and is still synced.

### Reading state at time `now`

After folding all events, settle once more using `now` in place of `t` (rule 1). Then:

- `timer.status` is `idle` if `current` is none, else the block's phase (`running` or `paused`).
- For a live block: `remaining_ms` is `planned_ms - elapsed_ms - (now - phase_since_ms)` when running, else `planned_ms - elapsed_ms`.
- For an ended block, `elapsed_ms` is final.

A block whose `timer.started` has not been seen but whose later events have been is ignored until it arrives; the later events are replayed in order when it does (total-order replay makes this automatic).

## Cycle

`long_break_every` is a setting (default 4), not an event. The suggested next kind after a block ends:

- After a focus block with outcome `completed`: let `n` be the number of `completed` focus blocks since the most recent ended `long_break` block (any outcome), counting from the start of the log if there is none. If `n >= long_break_every`, suggest `long_break`, else `short_break`.
- After a focus block with another outcome, or after any break: suggest `focus`.
- With no ended block: suggest `focus`.

## Statistics

Per block, the counted time is `elapsed_ms` (so a completed block counts its `planned_ms`, and a skipped or abandoned block counts the time it actually ran).

- **Focus time** for a period: sum of `elapsed_ms` over focus blocks whose `started_ms` falls in the period (any outcome).
- **Completed focus blocks**: count of focus blocks with outcome `completed`.
- A **day** is a calendar day in the timezone passed by the caller (an IANA name or a fixed UTC offset in minutes); `started_ms` decides the day.
- A **streak** is the number of consecutive days, ending today or yesterday, that each have at least one completed focus block.

## Commands

A Command is a request that the Core validates against the current state at wall time `now` and turns into exactly one event with a fresh HLC (so one `command_key` maps to at most one event).

| Command | Valid when | Events |
| --- | --- | --- |
| `start(kind, planned_ms, label?, project?)` | always | `timer.started` with a new `block_id` |
| `pause` | a block is running | `timer.paused` |
| `resume` | a block is paused | `timer.resumed` |
| `extend(add_ms)` | a block is live | `timer.extended` |
| `skip` | a block is live | `timer.skipped` |
| `stop` | a block is live | `timer.stopped` |
| `reset` | a block is live | `timer.reset` |
| `label(block_id?, label, project?)` | `block_id` known (default: current, else the most recent block) | `block.labeled` |

A Command carries an idempotency key. Issuing a Command whose `(device_id, command_key)` was already used returns the originally produced events and writes nothing. An invalid Command returns an error and writes nothing.
