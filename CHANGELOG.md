# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

## [0.1.0] - unreleased

First public snapshot.

### Changed
- An agent's `start_focus` / `start_break` over a running block is refused unless it passes `replace: true`; the HTTP start body gains `if_idle` and `pomo start` gains `--if-idle`.
- Every `pomo` command now has a help description.
- Licence is MIT only (was MIT OR Apache-2.0); `LICENSE-MIT` is now `LICENSE` and `LICENSE-APACHE` is removed.
- Signed and notarised Mac release flow (`bundle.sh` with `SIGN_IDENTITY`, `release.sh`, Homebrew cask `hmrdkn-labs/tap/pomo`).
- `bundle.sh` stops early with a clear message when only the Command Line Tools are installed (full Xcode is required).
- Cargo.lock bumps to clear RUSTSEC advisories.

### Added
- Daily update check in the Mac app (Sparkle), off-switch in Settings; one request a day to GitHub for the appcast.
- Rust core: event log, pure timer reducer, SQLite store, statistics, normative test vectors (`spec/`).
- Peer-to-peer sync over iroh with single-use pairing tickets and device revocation.
- `pomod` daemon with a localhost HTTP API, `pomo` CLI, and an MCP server over stdio.
- Mac menu bar app (SwiftUI) with popover, stats, settings, device pairing and global shortcuts.
- iPhone app (SwiftUI) with Live Activity, widget, local notifications and QR pairing, plus an XCUITest
  end-to-end suite.
- "Paper and ink" design system and shared design tokens.

### Security
- Event and payload bounds, clock-skew handling, atomic ingest, single-instance lock, Host/Origin checks,
  stream and connection caps, token permission hardening (see `spec/events.md` and `SECURITY.md`).
