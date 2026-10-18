# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's
[private vulnerability reporting](https://github.com/hmrdkn-labs/pomo/security/advisories/new)
for this repository. Do not open a public issue. Include what you found, how to reproduce it, and the
affected version or commit. You can expect an acknowledgement within a week.

Pomo is early software maintained by one person; there is no bug bounty.

## Threat model

Pomo is a personal tool. These are the intended boundaries:

- **Local API.** `pomod` binds to `127.0.0.1` only. Every request needs a bearer token stored in
  `$POMO_HOME/token` (mode 600). Requests must carry a loopback `Host` header and no `Origin` header, and
  POST bodies must be `application/json`, which blocks DNS rebinding and cross-site requests from browsers.
  Anyone who can read the token file, or who runs as your user, can control your timer.
- **Sync.** Devices authenticate each other by their iroh key. A device only syncs with devices you paired by
  scanning a single-use, five-minute ticket. Traffic is end-to-end encrypted. Relays see connection metadata,
  not content.
- **Paired devices are fully trusted.** A paired device can send events that claim to come from another of
  your devices. There are no per-event signatures yet. Revoke a device with `pomo revoke`, and only pair
  devices you own. Event timestamps and durations are bounded and validated on ingest to limit what a
  misbehaving peer can do.
- **Agents.** An agent with access to the API token or the `pomo` CLI can start, stop and label blocks and read
  your history. It cannot reach other devices except through sync with a paired device.
- **No telemetry.** Pomo sends no analytics or crash reports.

## Known limitations

- No event signing (see above).
- Mac builds are ad-hoc signed and not notarised; iPhone builds require you to sign with your own team.
- The iroh secret key is stored as a plain file with mode 600 under the data directory.
