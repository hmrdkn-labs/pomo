# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

First public snapshot.

### Added
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
