# Agent API (spec v1)

The Daemon (`pomod`) serves this over HTTP on `127.0.0.1` only. The CLI (`pomo`) and the MCP server (`pomo mcp`) are thin clients of it. All three produce the same results for the same operation.

## Setup

- Data directory: `$POMO_HOME`, default `~/.pomo`. Holds `pomo.db` (the store), `token` (random 32 bytes, base64url, file mode `600`, created on first Daemon start), `daemon.json` (`{"port": N, "pid": N}` written when listening, mode `600`) and `daemon.lock`.
- One Daemon per data directory: it takes an exclusive `flock` on `$POMO_HOME/daemon.lock` before opening the store and holds it until it exits; a second `pomod` on the same directory fails to start with a message saying so. The HTTP port is bound before the sync node starts.
- `token`, `daemon.json` and `daemon.lock` are opened without following symlinks (a symlink is refused). An existing `token` with group or other permissions is set back to `600` on start.
- The store's first creation and every migration run in one transaction together with the `meta.schema_version` bump. A store whose `schema_version` is newer than the build understands, or is not a positive integer, is refused with a clear error (the Daemon does not start) instead of being written to.
- Default port 47831; `--port 0` picks a free one and records it in `daemon.json`.
- Every request must have `Host` equal to `127.0.0.1:<port>` or `localhost:<port>` (else `403 bad_host`, DNS rebinding) and must not carry an `Origin` header (else `403 bad_origin`; native clients send none, browsers always do on cross-site requests). Both checks come before authentication.
- Every request needs `Authorization: Bearer <token>`. Missing or wrong token: `401`.
- A `POST` that has a body needs `Content-Type: application/json` (else `415 unsupported_media_type`). A `POST` without a body (`/v1/pair/offer`, `/v1/sync`, `/v1/devices/{id}/revoke`) needs no content type.
- Optional header `X-Pomo-Source: agent:<name>` sets the event `source` (default `user`). Names match `[a-z0-9_-]{1,32}`.
- Optional header `Idempotency-Key: <string>` on `POST /v1/commands`; if absent the Daemon uses a fresh UUID (so the request is not retry-safe).
- Bodies and responses are JSON, UTF-8. Times are integer ms. Errors: `{"error": {"code": "<snake_case>", "message": "<text>"}}` with `400` (bad input, including a command whose event would break the "Validity bounds" of `events.md`: `planned_ms` and `add_ms` must be in `1..=86400000`, and a block cannot exceed 48 h in total), `401`, `403`, `404`, `409` (command invalid for the current state: `invalid_state`), `415`, `500`, `503` (`too_many_streams`).

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
Events the caller lacks, for sync diagnostics and export. Default `limit` 1000, maximum 10000 (larger values are clamped). The page holds, for each Device, a prefix of its `seq` run above the caller's vector entry (Devices in `device_id` order, filled up to `limit`), sorted into total order. To read on, advance the vector by the highest `seq` seen per Device and ask again. Vector entries above 2^63 - 1 are clamped.

### `GET /v1/stream`
Server-sent events. Event `pomo.event` with the Event JSON as data, one per newly stored event (local or synced); event `pomo.block_end` with `{"block_id","outcome":"completed","ended_ms"}` when a running block reaches its end time (the Daemon schedules a timer for this; it writes no event). Event `pomo.resync` with `{"missed": N}` when this client fell behind and events were dropped (N is how many): the client must refetch its state (`/v1/status`, `/v1/blocks`) instead of trusting the events it saw; the stream then continues. A comment line `: keepalive` every 15 s. At most 16 streams are open at once; a 17th request gets `503 too_many_streams`.

## CLI

`pomo <command> [--json] [--home DIR]`. Commands: `start [--kind focus|short|long] [--minutes N] [--label TEXT] [--project TEXT]` (default focus, 25 minutes; short 5; long 15), `pause`, `resume`, `extend --minutes N`, `skip`, `stop`, `reset`, `label TEXT [--block ID] [--project TEXT]`, `status`, `blocks [--since 7d] [--limit N]`, `stats [--since 7d] [--by day|label|project]`, `events --follow`, `mcp`. `--minutes` (and the MCP `minutes` arguments) must be a finite number greater than 0 and at most 1440 (24 h); anything else is rejected with a message before any request is made. `--source agent:<name>` sets the source header. Human output is one tidy line or a small table; `--json` prints exactly the API response body. Exit code 0 on success, 1 on a request error, 2 if the Daemon is not reachable (message says how to start it).

## MCP (`pomo mcp`, stdio)

Tools, each returning the API response as JSON text, all with `source = agent:<mcp-client-name>` taken from the client's `initialize` info (fallback `agent:mcp`): `start_focus(minutes?, label?, project?)`, `start_break(kind: short|long, minutes?)`, `pause`, `resume`, `stop`, `skip`, `extend(minutes)`, `reset`, `label_block(label, project?, block_id?)`, `get_status`, `list_blocks(since?, limit?)`, `get_stats(since?, group_by?)`. `since` accepts `7d`, `24h` or an ISO-8601 timestamp. Tool descriptions say plainly what each does and what state it needs. A failed Command is returned as a tool error with the API error message.

## Devices and sync (added with the sync integration)

`pomod` runs a `pomo-sync` node. Flags: `--sync n0|local|off` (default `n0`: real relays; `local`: no relays, for tests; `off`: no node, the endpoints below return `501 sync_disabled`) and `--name <device name>` (default: the machine's hostname). The Daemon's `device_id` is its iroh endpoint id; the key lives in `$POMO_HOME/meta/key`. Events ingested from peers are published on `/v1/stream` like local ones.

- `GET /v1/devices` → `{"device_id": "<own>", "name": "<own>", "devices": [{"device_id","name","paired","revoked"}]}` (own Device excluded from the list).
- `POST /v1/pair/offer` → `{"ticket": "pomo-pair:...", "expires_ms": N}`. The ticket is single use, five minutes.
- `POST /v1/pair/join` body `{"ticket": "...", "name": "<optional own name override>"}` → `{"device": {...}}`; pairs and runs one sync session. `400 bad_ticket`, `409 pairing_rejected` (with the peer's reason).
- `POST /v1/sync` body `{"device_id": "<optional>"}` → `{"synced": [{"device_id","sent","received"}]}`; without `device_id`, syncs with every paired, non-revoked Device whose address is known; per-peer failures are reported as `{"device_id","error"}` entries, not an HTTP error.
- `POST /v1/devices/{device_id}/revoke` → `{"device": {...}}`.

CLI: `pomo devices`, `pomo pair offer` (prints the ticket and a terminal QR code), `pomo pair join <ticket>`, `pomo sync [--device ID]`, `pomo revoke <device_id>`.
