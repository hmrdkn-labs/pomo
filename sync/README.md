# pomo-sync

Peer-to-peer Sync over [iroh](https://docs.iroh.computer/) (`iroh = 1.3.0`, `iroh-tickets = 1.0.0`), implementing `spec/sync.md`.
Builds on `pomo-core`: trust (`devices`), peer addresses (`peers`) and the all-or-nothing frame ingest all go through Core APIs; the crate has no database connection of its own.

## Use

```rust
use pomo_sync::{SyncNode, SyncOptions};

// Opens <db dir>/meta/key (created with mode 600) and the store with the key's endpoint id
// as device_id, then starts the listener for ALPN `pomo/sync/1`.
let node = SyncNode::open("/path/to/pomo.db", SyncOptions::default()).await?;
node.device_id();                                   // endpoint id (hex) == store device_id

// Pairing: device A offers, device B joins (one session runs right after).
let t = node_a.pairing_ticket("laptop").await?;      // PairingTicket { ticket: "pomo-pair:<base64url json>", expires_ms }; 5 min, one use
let out = node_b.pair(&t.ticket, "phone").await?;    // PairOutcome { device_id, name, sync }

// Later sessions, by device id (address persisted in the store's `peers` table, so it survives
// restarts; on `Network::N0` also found by address lookup) or by an endpoint ticket
// (`node.endpoint_ticket().await`).
let report = node_b.sync_with(&out.device_id).await?; // SyncReport { sent, received, live, .. }

node.set_live(true);                 // ask peers to keep sessions open and forward new events (Daemon / foreground)
node.has_session(&device_id);        // a session with that device is open (either direction)
node.knows_address(&device_id);      // sync_with has an address to dial
let mut rx = node.subscribe();       // Vec<Event> per frame newly stored from peers (for SSE)
node.apply(cmd, source, now_ms)?;    // store.apply + forward to live peers
node.notify();                       // call after writing to the store directly
node.revoke(&device_id)?;            // closes its sessions, rejects it from now on
node.shutdown().await;
```

Lower level: `open_store(db_path, key_path)` returns the `Store` and `SecretKey` (device id = key's endpoint id);
`SyncNode::start(store, key, opts)` takes an `Arc<Mutex<Store>>` the caller also uses for commands (the Daemon does).
`pomo_sync::wire` exposes the frame codec.

## Options (`SyncOptions`)

| Field | Default | Meaning |
| --- | --- | --- |
| `network` | `N0` | `N0`: iroh N0 preset (default n0 relays, n0 address lookup). `Local`: loopback only, no relay, no lookup; peers are reached through ticket addresses (`SyncOptions::local()`). |
| `live` | false | initial live flag |
| `ticket_ttl` | 5 min | pairing ticket validity |
| `events_per_frame` | 500 | at most 500 |
| `ping_interval` / `idle_timeout` | 20 s / 60 s | live-mode ping, silent-session limit |
| `drop_after_frames` | none | test hook: once, drop the connection before event frame n+1 |

## Behaviour notes

- Trust lives in the store's `devices` table (`paired`, `revoked`), read and written with `Store::device` / `set_device_paired` / `set_device_revoked`.
- Re-pairing a revoked device with a valid ticket clears the revocation.
- The hello carries `live`. After both `done`s the stream stays open when either side is live, and both sides then forward new events and ping. A side that is not live keeps a stream the peer asked for until the peer says `bye` or closes. When neither is live, both say `bye`. A side that goes from live to not live (`set_live(false)`) says `bye`. The peer's flag is the one from its hello. `SyncReport::live` is true when the stream stays open. Sessions are not re-dialed automatically; call `sync_with` again.
- Received frames are checked before storing: a `(device_id, seq)` or command-key conflict (`Store::ingest_atomic`) aborts the session and stores nothing from the frame; a `seq` gap drops that device's events from the frame and aborts; events of our own device beyond what we issued abort.
- The pairing secret is 16 random bytes, base64url without padding.

## Tests

`cargo test -p pomo-sync` runs everything locally (loopback, no relay). `cargo test -p pomo-sync -- --ignored` additionally pairs and syncs through the real n0 relays (needs internet).
