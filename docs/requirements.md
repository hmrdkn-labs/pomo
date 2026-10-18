# Requirements

Terms follow `../CONTEXT.md`. Priority: **P0** first release, **P1** soon after, **P2** later.

## Goals

1. A calm, native Pomodoro timer on Mac and iPhone, in the spirit of Kofe Flow.
2. One live Timer and one history shared across all of a user's Devices, with no account and no cloud.
3. Agents can start timers and measure time spent as first-class users.
4. Portable to Android, Windows, Linux and web later without redesign.

## Non-goals

- Task management. Pomo holds time; the user's task system holds work.
- Multi-user, teams, sharing, social features.
- Any hosted backend or account system.
- Subscriptions or ads.

## Functional requirements

### Timer

| ID | Requirement | Pri |
| --- | --- | --- |
| T1 | Start a focus block, short break or long break with a configurable duration | P0 |
| T2 | Pause, resume, extend, skip, reset and stop | P0 |
| T3 | Defaults 25 / 5 / 15 min, long break after 4 focus blocks, all configurable | P0 |
| T4 | Optional auto-start of the next block | P1 |
| T5 | Exactly one Timer across all Devices; a Command on any Device updates all | P0 |
| T6 | Remaining time is computed from absolute timestamps on each Device; never ticked over the network | P0 |
| T7 | A block that ends while the app is closed or the Device asleep is still recorded correctly | P0 |
| T8 | A label may be attached at start or afterward | P0 |

### Alerts

| ID | Requirement | Pri |
| --- | --- | --- |
| A1 | A notification at block end on every Device that is not already showing the Timer | P0 |
| A2 | Sound choice and mute | P1 |
| A3 | iPhone Lock Screen and Dynamic Island countdown | P0 |
| A4 | Quiet nudge suggesting to start or pause | P2 |

### History and statistics

| ID | Requirement | Pri |
| --- | --- | --- |
| H1 | Every completed, skipped and abandoned block is stored with start, end, kind, label, Source, Device | P0 |
| H2 | Focus time per day, week, month; streaks | P0 |
| H3 | Focus time grouped by label and by Project | P1 |
| H4 | Edit a block's label or Project after the fact; edits are Events | P1 |
| H5 | Export all data as JSON and CSV | P1 |
| H6 | Per-app and per-website activity during blocks, stored on the Mac only and never synced | P2 |

### Sync

| ID | Requirement | Pri |
| --- | --- | --- |
| S1 | Peer-to-peer Sync between a user's Devices over iroh, end-to-end encrypted | P0 |
| S2 | Pair a new Device once by scanning a QR code | P0 |
| S3 | Every Device works fully offline and converges when it reconnects | P0 |
| S4 | Applying the same Events in any order, any number of times, yields the same state | P0 |
| S5 | A Device can be revoked; it stops receiving Events | P1 |
| S6 | Sync works across networks without port forwarding or a VPN | P0 |
| S7 | An optional always-on peer (the same Daemon on a small box) | P2 |

### Agents

| ID | Requirement | Pri |
| --- | --- | --- |
| G1 | The Daemon serves a localhost HTTP API with a local token | P0 |
| G2 | A `pomo` CLI with `--json` output over the same operations | P0 |
| G3 | An MCP server (`pomo mcp`) exposing start, pause, resume, stop, status, list blocks, stats, label | P0 |
| G4 | Every Command takes an idempotency key; retries never double-apply | P0 |
| G5 | Statistics are aggregated by the Daemon; the Agent gets totals, not raw rows to crunch | P0 |
| G6 | Each block records its Source, so human and agent blocks are distinguishable | P0 |
| G7 | An event stream (`pomo events --follow`) so an Agent can react when a block ends | P1 |
| G8 | Agents get scoped tokens (read-only or read-write), revocable | P1 |

### Mac app

| ID | Requirement | Pri |
| --- | --- | --- |
| M1 | Menu bar item showing the live countdown | P0 |
| M2 | Compact popover with start, pause, extend, skip, reset | P0 |
| M3 | Global keyboard shortcuts | P1 |
| M4 | Open at login; hide the Dock icon | P0 |
| M5 | The Daemon keeps running when the menu bar app is quit | P1 |
| M6 | Focus statistics window | P1 |

### iPhone app

| ID | Requirement | Pri |
| --- | --- | --- |
| I1 | Timer screen with start, pause, extend, skip, reset | P0 |
| I2 | Live Activity and local notification scheduled from the block end time | P0 |
| I3 | Home and Lock Screen widgets | P1 |
| I4 | App Intents for Shortcuts and Siri | P1 |
| I5 | Statistics screen | P1 |
| I6 | Apple Watch companion | P2 |

## Non-functional requirements

| ID | Requirement |
| --- | --- |
| N1 | **Local only.** No account, no hosted service, no third-party analytics. The only external dependency is iroh relays for connection setup, and these may be self-hosted. |
| N2 | **Native shells.** Each platform's UI uses its own toolkit. The Core is a Rust library, not a UI runtime. |
| N3 | **Portable store.** One SQLite schema, byte-compatible across platforms. Events are canonical; Projections can be rebuilt. |
| N4 | **Correctness first.** The timer rules are pure functions covered by shared test vectors that every Core build passes. |
| N5 | **Responsive.** Menu bar and Live Activity update with no perceptible lag; a Command applies locally in under 50 ms before any sync. |
| N6 | **Idle cost.** The Daemon uses negligible CPU and wakes only on a Command, a peer connection or a block end. |
| N7 | **Privacy.** Activity data (H6) never leaves the Device that recorded it. Synced data is Events about blocks only. |
| N8 | **Data ownership.** All data can be exported, and the SQLite file opens in any SQLite tool. |

## Constraints

- Apple Developer account is available (Live Activities, TestFlight, APNs, signing).
- iOS cannot hold a connection while suspended. Sync happens when the app opens or on a silent push; the timer stays correct from absolute timestamps and local notifications.
- iroh bindings cover the stable core (endpoints, connections, tickets, relays), not iroh-docs, gossip or blobs. The Sync protocol is ours.

## Open questions

1. Is a silent-push path (APNs) worth adding for iPhone background Sync, or is sync-on-open enough?
2. Does an always-on peer matter in practice, given the phone works offline and the Mac is usually on?
3. Which Windows and Linux Shells, when the time comes?
4. Web: a read-only view served by the Daemon, or a WASM build of the Core?
