# Sync protocol (spec v1)

Peer-to-peer over [iroh](https://docs.iroh.computer/) connections. No server. A Device's `device_id` is its iroh endpoint id (public key) in the string form iroh prints. Events are as in `events.md`; this file only says how Devices exchange them.

## Transport

- ALPN: `pomo/sync/1`.
- One bidirectional QUIC stream per sync session, opened by the dialing Device.
- Frames: 4-byte big-endian length, then a UTF-8 JSON object with a `t` field. Maximum frame 4 MiB.

## Trust

- Only paired Devices may sync. A listener checks the remote endpoint id (authenticated by iroh) against `devices.paired = 1 AND revoked = 0`. Anything else may only perform the Pairing handshake below.
- Events about Devices that are not the sender are accepted (Devices relay each other's events), but only from a paired peer.

## Pairing

1. The offering Device creates a **pairing ticket**: the iroh endpoint ticket (its id plus relay and direct addresses) and a random 16-byte `secret`, encoded as one string `pomo-pair:<base64url(json {ticket, secret, name})>`. It is valid for 5 minutes and one use, and is shown as a QR code (and copyable text).
2. The joining Device dials the ticket's address and sends `{"t":"pair","secret":"<secret>","device_id":"<own>","name":"<own name>"}` as its first frame.
3. The offerer checks the secret (constant-time), single use and expiry. On success it marks the joiner `paired = 1`, replies `{"t":"pair_ok","device_id":"<own>","name":"<own name>"}`, and the joiner marks the offerer `paired = 1`. Then the normal exchange below follows on the same stream. On failure it replies `{"t":"reject","reason":"bad_secret|expired|used"}` and closes.

## Exchange

1. Dialer sends `{"t":"hello","device_id":"...","vv":{"<device_id>": <max seq>, ...}}`.
2. Listener replies with its own `hello`. A Device that does not trust the peer replies `{"t":"reject","reason":"unpaired|revoked"}` and closes.
3. Each side computes the events the other lacks (events with `seq > vv[device_id]`, in total order) and sends them as `{"t":"events","events":[...]}` frames of at most 500 events, then `{"t":"done"}`. Each side ingests received events (idempotent by id; a `(device_id, seq)` conflict aborts the session and is logged).
4. After both `done`s the stream stays open in **live mode** when either side is a Daemon or app in the foreground: each newly stored event (local or ingested) is forwarded as an `events` frame to peers that have not got it. A side that is not running live closes the stream with `{"t":"bye"}`.
5. A `ping` frame every 20 s in live mode; 60 s without any frame closes the session.

Gaps in `seq` from one Device (events missing in the middle) are not possible because each side sends all events above the peer's vector entry; a receiver that sees a gap anyway stores nothing from that Device in that frame and asks again by closing and reconnecting.

## Properties required

- Two Devices that start with different logs and both run one session end with the same log.
- Three Devices A, B, C where A pairs with B and B pairs with C (not A and C): events from A reach C through B.
- A session interrupted at any point leaves a consistent store; the next session completes the exchange.
- A revoked Device's session is rejected.
