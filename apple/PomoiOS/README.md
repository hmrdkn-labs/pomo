# Pomo for iPhone

SwiftUI app (iOS 17+) with a widget extension. The Rust Core and the iroh Sync node run **inside the app
process** through UniFFI (`ffi/` crate → `apple/PomoKit`). There is no daemon on the phone; paired with the
Mac's `pomod` it shares one Timer and one history.

| Path | What |
| --- | --- |
| `ffi/` | `pomo-ffi` crate: `PomoCore` object, records, `PomoListener` callback |
| `apple/PomoKit` | Swift package: `PomoKit` (FFI adapter implementing PomoUI's `PomoAPI`/`DevicesAPI`, `SyncCoordinator`), `PomoLive` (pure Swift: notification, Live Activity and widget logic) |
| `apple/shared` | `PomoUI`: design tokens, view-models, countdown logic (shared with the Mac app) |
| `apple/PomoiOS` | this app: `Sources/App`, `Sources/Widgets`, `Tests`, `project.yml` |

## Build

Prerequisites: Xcode with the iOS SDK, `rustup` (the script adds `aarch64-apple-ios`,
`aarch64-apple-ios-sim`, `aarch64-apple-darwin`), and XcodeGen (`nix run nixpkgs#xcodegen -- ...` or
`brew install xcodegen`).

```sh
# 1. Rust → apple/PomoKit/PomoFFI.xcframework (not checked in) + generated Swift in Sources/PomoCoreFFI
apple/PomoKit/scripts/build-xcframework.sh          # --debug for a debug build

# 2. Xcode project (not checked in)
cd apple/PomoiOS && nix run nixpkgs#xcodegen -- generate

# 3. Build without signing
xcodebuild -project Pomo.xcodeproj -scheme Pomo -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

The simulator slice is arm64 only (Apple-silicon Macs). Re-run step 1 after any change in `ffi/`, `core/` or
`sync/`; it also regenerates `Sources/PomoCoreFFI/pomo_ffi.swift` (checked in).

Tests: `cd apple/PomoKit && swift test` (macOS slice: a real Core in a temp dir, two Cores pairing and syncing
in one process over the loopback network), `cd apple/shared && swift test`, `cargo test -p pomo-ffi`.
The app's own unit tests (`PomoTests`) need a simulator runtime: `xcodebuild test -scheme Pomo -destination
'platform=iOS Simulator,name=<device>'`. Without a runtime they can still be compiled:
`xcodebuild -scheme Pomo -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build-for-testing
CODE_SIGNING_ALLOWED=NO ARCHS=arm64` (`ARCHS=arm64` because Xcode builds dynamic package products for every
architecture in that mode, and the Rust library has no x86_64 slice).

A widget-only build: `-scheme PomoWidgets`. A device-SDK build: `-sdk iphoneos -destination 'generic/platform=iOS'`.

## Install on your iPhone

1. Open `apple/PomoiOS/project.yml` and set `DEVELOPMENT_TEAM` to your team id (Xcode → Settings → Accounts, or
   developer.apple.com → Membership). Or leave it and pick the team in Xcode under *Signing & Capabilities* for
   both the `Pomo` and `PomoWidgets` targets; run `xcodegen generate` again if you edit `project.yml`.
2. Register the App Group `group.dev.hamardikan.pomo` (developer.apple.com → Identifiers → App Groups), and the
   two App IDs `dev.hamardikan.pomo.ios` and `dev.hamardikan.pomo.ios.widgets`, both with that group enabled.
   Automatic signing creates the App IDs; the group is the one step it may ask you to confirm. The Live
   Activities capability needs no separate switch: `NSSupportsLiveActivities` is in the Info.plist.
3. Plug the iPhone in, enable Developer Mode (Settings → Privacy & Security → Developer Mode), select it as the
   run destination, and run the `Pomo` scheme. Allow notifications on the first start, camera when scanning, and
   Local Network when asked (direct connections to the Mac on the same Wi-Fi).
4. Live Activities must be on: Settings → Pomo → Live Activities.
5. For TestFlight, archive the `Pomo` scheme, set the export-compliance answer (the app uses standard TLS through
   iroh) and upload as usual.

## Pair with the Mac

On the Mac run `pomo pair offer` (prints a QR code and a `pomo-pair:...` ticket), or use the Devices section of the
menu bar app's Settings. On the iPhone open **Devices → Scan QR code**, or paste the ticket. Both screens then list the other
device. Pair once; afterwards the phone syncs by device id (the address is remembered, and iroh finds the Mac
through its relays when the addresses change). The ticket works once and expires after five minutes.

## Behaviour

- **Sync** runs when the app opens, when it returns to the foreground, every 60 s while it stays there, and from
  the *Sync now* button. While foregrounded the node is live: the Mac keeps a session open and events flow both
  ways within a second. In the background iOS suspends the app, nothing syncs, and the Timer stays right because
  every display derives from absolute end times.
- **Notification**: one local notification at the running block's end time, rescheduled or cancelled on every
  state change (start, pause, resume, extend, skip, stop, reset, an event synced from the Mac, block end). Not
  shown while the app is open (the sound plays).
- **Live Activity**: started, updated and ended from the same state changes, only while the app is in the
  foreground (ActivityKit starts activities from the foreground). Lock Screen and Dynamic Island show the ring and
  `Text(timerInterval:)`, drawn by the system, so the countdown ticks without the app. If a block ends while the
  app is suspended, the activity stays with its finished countdown ("Done") until the app next runs; ending it
  from the background would need a push (APNs), which is not built.
- **Widget** (small): today's focus time, read from the App Group snapshot the app writes after each state change.
- **Data** lives in `Application Support/Pomo` (`pomo.db`, `meta/key`), excluded from backups so a restored copy
  never impersonates the original device.

## Not built

App Intents / Shortcuts (I4), the Live Activity pause button (needs an App Intent), medium widget, lock screen
widgets, silent-push sync, sound choice. See `.work/reports/ios.md`.
