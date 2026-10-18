# Shared Rust Core with native UI Shells

The timer rules, storage, Sync and agent API logic live in one Rust library; each platform's UI is written natively (SwiftUI, Compose, and so on) and calls it through UniFFI bindings. We rejected a cross-platform UI runtime (Electron, Flutter) because the product's value is menu bar, Live Activity and widget integration, and rejected per-port reimplementation of the logic because Sync would then have to be kept identical in four languages.
