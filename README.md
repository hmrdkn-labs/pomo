# Pomo

A personal, local-only Pomodoro timer: native on every device, synced peer to peer over iroh, and built so my AI agents can run timers and measure time spent.

## Status

| Part | State |
| --- | --- |
| Rust Core (rules, SQLite event log, stats) | done, spec vectors and property tests pass |
| iroh peer-to-peer sync | done, tested locally and once through the n0 relays |
| Daemon `pomod`, `pomo` CLI, MCP server | done, hardened after two independent reviews |
| Mac menu bar app (`apple/PomoMac`) | built and tested; UI rendered offscreen, never watched in the real menu bar |
| iPhone app (`apple/PomoiOS`) | builds for simulator and device; never run (no simulator runtime installed) |
| Android, Windows, Linux, web | not started |

Known limits are in `docs/roadmap.md` and the worker reports kept out of git in `.work/reports/`.

## Docs

- [CONTEXT.md](CONTEXT.md): glossary
- [docs/requirements.md](docs/requirements.md)
- [docs/ui-reference.md](docs/ui-reference.md)
- [docs/roadmap.md](docs/roadmap.md)
- [docs/adr/](docs/adr/): decisions
- [spec/](spec/): events, sync protocol, agent API, schema, test vectors, design tokens

## Try it

```sh
cargo build --release -p pomod -p pomo-cli
target/release/pomod --port 0 --sync off &      # data in ~/.pomo
target/release/pomo start --minutes 25 --label "write spec"
target/release/pomo status --json
target/release/pomo stats --by label
```

Pair two devices: `pomo pair offer` on one (prints a QR), `pomo pair join <ticket>` on the other.
Mac app: `apple/PomoMac/scripts/bundle.sh`. iPhone: see `apple/PomoiOS/README.md`.
