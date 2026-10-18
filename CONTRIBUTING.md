# Contributing

Thanks for your interest. Pomo is small and opinionated; an issue before a large change saves everyone time.

## Ground rules

- **The spec is the contract.** Behaviour lives in [`spec/`](spec). If you change timer rules, events, sync or
  the API, change the spec and add test vectors in the same pull request. Vectors in `spec/vectors/` must pass
  for every implementation.
- **Vocabulary.** Use the terms in [CONTEXT.md](CONTEXT.md) (Block, Timer, Command, Event, Device, Daemon,
  Shell, Core). Prefer them over synonyms in code, docs and UI copy.
- **Design.** UI changes follow [docs/ui-reference.md](docs/ui-reference.md) and `spec/tokens.json`. The
  tokens are checked against the Swift constants by a test.
- **Decisions.** Hard-to-reverse choices get a short ADR in [docs/adr](docs/adr).
- **Privacy.** Nothing leaves a user's devices except iroh traffic. No telemetry, no accounts.

## Setup

```sh
rustup toolchain install stable
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
```

Apple targets need Xcode (Swift 6 toolchain) and, for the iPhone project, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). See [apple/PomoiOS/README.md](apple/PomoiOS/README.md).

## Pull requests

1. Keep the change focused. Include tests that fail without it.
2. `cargo test --workspace` and clippy with `-D warnings` must pass. For Apple changes run `swift test` in the
   packages you touched.
3. Describe what you ran and what you could not verify (for example, behaviour that needs a physical device).
4. By contributing you agree your work is licensed under the project's dual MIT OR Apache-2.0 licence.

## Reporting bugs

Open an issue with your OS and app version, what you did, what you expected, and what happened. For
vulnerabilities, see [SECURITY.md](SECURITY.md).
