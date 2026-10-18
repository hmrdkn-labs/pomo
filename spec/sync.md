# Sync protocol (spec v1)

Peer-to-peer over [iroh](https://docs.iroh.computer/) connections. No server. A Device's `device_id` is its iroh endpoint id (public key) in the string form iroh prints. Events are as in `events.md`; this file only says how Devices exchange them.

## Transport

- ALPN: `pomo/sync/1`.
- One bidirectional QUIC stream per sync session, opened by the dialing Device.
- Frames: 4-byte big-endian length, then a UTF-8 JSON object with a `t` field. Maximum frame 4 MiB.
- A Device remembers the last known address (the iroh endpoint ticket) of each peer it paired with or was given a ticket for, in the local `peers` table (migration `0002_peers.sql`; never synced), so it can dial by `device_id` after a restart.

## Trust model

- Only paired Devices may sync. A listener checks the remote endpoint id (authenticated by iroh) against `devices.paired = 1 AND revoked = 0`. Anything else may only perform the Pairing handshake below.
- Paired Devices are fully trusted: they are all mine. Events about Devices that are not the sender are accepted (Devices relay each other's events), but only from a paired peer. Nothing binds an event to the Device named in its `device_id`, so **a paired peer can forge events for another Device** (for example claim `(victim, seq + 1)` before the victim does, after which the victim's real event at that `seq` is a conflict). Events carry no signatures.
- Mitigation: revoke the Device (this closes its sessions and refuses it from then on) and pair again; the other Devices' logs keep what the forger already relayed. Signing each event with its issuer's key, verified by every receiver, is a possible v2; it is deliberately out of scope for v1.
- What a peer cannot do, because the receiver enforces it: store an event that fails the "Validity bounds" of `events.md`; make the receiver's clock jump by more than a day (events more than 24 h ahead of the receiver's wall clock are skipped and offered again later); leave a hole in a Device's `seq` run; forge events of the receiver itself (the receiver rejects `seq`s above its own maximum).
- Resource limits: a session ends with an error once the peer has sent 50 000 events in it (what was stored stays; the next session continues), and at most 16 connections from Devices that are not trusted are served at the same time until they pair; further ones are dropped at once.

## Pairing

1. The offering Device creates a **pairing ticket**: the iroh endpoint ticket (its id plus relay and direct addresses) and a random 16-byte `secret`, encoded as one string `pomo-pair:<base64url(json {ticket, secret, name})>`. It is valid for 5 minutes and one use, and is shown as a QR code (and copyable text).
2. The joining Device dials the ticket's address and sends `{"t":"pair","secret":"<secret>","device_id":"<own>","name":"<own name>"}` as its first frame.
3. The offerer checks the secret (constant-time), single use and expiry. On success it marks the joiner `paired = 1`, replies `{"t":"pair_ok","device_id":"<own>","name":"<own name>"}`, and the joiner marks the offerer `paired = 1`. Then the normal exchange below follows on the same stream. On failure it replies `{"t":"reject","reason":"bad_secret|expired|used"}` and closes.

## Exchange

1. Dialer sends `{"t":"hello","device_id":"...","vv":{"<device_id>": <max seq>, ...},"live":<bool>}`. `live` is true when the sender is a Daemon or an app in the foreground and wants the stream kept open; an absent `live` means false.
2. Listener replies with its own `hello` (same fields, its own `live`). A Device that does not trust the peer replies `{"t":"reject","reason":"unpaired|revoked"}` and closes.
3. Each side computes the events the other lacks (events with `seq > vv[device_id]`) and sends them as `{"t":"events","events":[...]}` frames of at most 500 events, then `{"t":"done"}`. Each Device's events are sent in `seq` order (never in total order), a page at a time, so a frame never skips ahead of an event the receiver has not stored; entries of `vv` above 2^63 - 1 are clamped. Each side ingests received events (idempotent by id). A frame is stored all or nothing: a `(device_id, seq)` conflict anywhere in it stores nothing from the frame, aborts the session and is logged; so does an event that fails the "Validity bounds" of `events.md` (no event of the frame is stored, so there are no `seq` holes). An event more than 24 h ahead of the receiver's clock is not an error: it and the rest of that Device's run are skipped for the session, and offered again at the next one.
4. After both `done`s the stream stays open in **live mode** when **either** side's hello had `live: true`: each newly stored event (local or ingested) is forwarded as an `events` frame to the peer. A side that is not live, but whose peer is, has finished sending but keeps the stream until the peer sends `{"t":"bye"}` or closes. When neither hello was live, both sides send `bye` and close. A side that stops being live during the session (a Daemon never does; an app does when it goes to the background) sends `bye`. The peer's flag is the one from its hello; it is not updated mid-session.
5. In live mode both sides send a `ping` frame every 20 s (so a side that only listens is not timed out); 60 s without any frame closes the session.

Gaps in `seq` from one Device (events missing in the middle) are not possible because each side sends all events above the peer's vector entry; a receiver that sees a gap anyway stores nothing from that Device in that frame and asks again by closing and reconnecting.

## Properties required

- Two Devices that start with different logs and both run one session end with the same log.
- Three Devices A, B, C where A pairs with B and B pairs with C (not A and C): events from A reach C through B.
- A session interrupted at any point leaves a consistent store; the next session completes the exchange.
- A revoked Device's session is rejected.
