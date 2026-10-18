# Agent API (spec v1)

The Daemon (`pomod`) serves this over HTTP on `127.0.0.1` only. The CLI (`pomo`) and the MCP server (`pomo mcp`) are thin clients of it. All three produce the same results for the same operation.

## Setup

- Data directory: `$POMO_HOME`, default `~/.pomo`. Holds `pomo.db` (the store), `token` (random 32 bytes, base64url, file mode `600`, created on first Daemon start) and `daemon.json` (`{"port": N, "pid": N}` written when listening).
- Default port 47831; `--port 0` picks a free one and records it in `daemon.json`.
- Every request needs `Authorization: Bearer <token>`. Missing or wrong token: `401`.
- Optional header `X-Pomo-Source: agent:<name>` sets the event `source` (default `user`). Names match `[a-z0-9_-]{1,32}`.
- Optional header `Idempotency-Key: <string>` on `POST /v1/commands`; if absent the Daemon uses a fresh UUID (so the request is not retry-safe).
- Bodies and responses are JSON, UTF-8. Times are integer ms. Errors: `{"error": {"code": "<snake_case>", "message": "<text>"}}` with `400` (bad input), `401`, `404`, `409` (command invalid for the current state: `invalid_state`), `500`.

## Endpoints

### `GET /v1/status`
`{"now_ms": N, "timer": Timer, "today": {"focus_ms": N, "completed_focus": N}}` where `today` uses the `tz_offset_min` query parameter (default: the Daemon's local offset).

`Timer` = `{"status": "idle|running|paused", "block": Block|null, "remaining_ms": N|null, "next_kind": "focus|short_break|long_break"}`.

`Block` = `{"id","kind","label","project","source","device_id","started_ms","planned_ms","elapsed_ms","phase","outcome","ended_ms"}` (fields as in `events.md`; `outcome` and `ended_ms` null while live). For a live block `elapsed_ms` is the value at `now_ms`.

### `POST /v1/commands`
Body: a Command, `{"type": "start|pause|resume|extend|skip|stop|reset|label", ...fields per events.md}`; durations as `planned_ms` / `add_ms`.
`200`: `{"event": Event, "timer": Timer, "replayed": bool}` (`replayed` true when the idempotency key was already used).
`409` when invalid for the current state.

### `GET /v1/blocks?from_ms=&to_ms=&kind=&limit=`
Blocks with `started_ms` in `[from_ms, to_ms)`, newest first, default limit 100, max 1000. `{"blocks": [Block]}`.

### `GET /v1/stats?from_ms=&to_ms=&tz_offset_min=&group_by=day|label|project`
`{"from_ms","to_ms","tz_offset_min","focus_ms": N, "completed_focus": N, "streak_days": N, "groups": [{"key": "<day|label|project>", "focus_ms": N, "completed_focus": N}]}`. Groups sorted by `focus_ms` descending (by key ascending for `day`). A block with no label or project is grouped under key `""`. Aggregation is done by the Daemon.

### `GET /v1/events?after=<url-encoded JSON version vector>&limit=`
Events the caller lacks, in total order. For sync diagnostics and export.

### `GET /v1/stream`
Server-sent events. Event `pomo.event` with the Event JSON as data, one per newly stored event (local or synced); event `pomo.block_end` with `{"block_id","outcome":"completed","ended_ms"}` when a running block reaches its end time (the Daemon schedules a timer for this; it writes no event). A comment line `: keepalive` every 15 s.

## CLI

`pomo <command> [--json] [--home DIR]`. Commands: `start [--kind focus|short|long] [--minutes N] [--label TEXT] [--project TEXT]` (default focus, 25 minutes; short 5; long 15), `pause`, `resume`, `extend --minutes N`, `skip`, `stop`, `reset`, `label TEXT [--block ID] [--project TEXT]`, `status`, `blocks [--since 7d] [--limit N]`, `stats [--since 7d] [--by day|label|project]`, `events --follow`, `mcp`. `--source agent:<name>` sets the source header. Human output is one tidy line or a small table; `--json` prints exactly the API response body. Exit code 0 on success, 1 on a request error, 2 if the Daemon is not reachable (message says how to start it).

## MCP (`pomo mcp`, stdio)

Tools, each returning the API response as JSON text, all with `source = agent:<mcp-client-name>` taken from the client's `initialize` info (fallback `agent:mcp`): `start_focus(minutes?, label?, project?)`, `start_break(kind: short|long, minutes?)`, `pause`, `resume`, `stop`, `skip`, `extend(minutes)`, `reset`, `label_block(label, project?, block_id?)`, `get_status`, `list_blocks(since?, limit?)`, `get_stats(since?, group_by?)`. `since` accepts `7d`, `24h` or an ISO-8601 timestamp. Tool descriptions say plainly what each does and what state it needs. A failed Command is returned as a tool error with the API error message.
