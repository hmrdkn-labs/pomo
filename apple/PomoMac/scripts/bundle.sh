#!/bin/bash
# Assemble Pomo.app (menu bar app) with embedded pomod, pomo and the Sparkle updater.
#
#   scripts/bundle.sh [output-dir]       default output: apple/PomoMac/.build/bundle
#   SKIP_RUST=1 scripts/bundle.sh        (0 or unset: build) reuse the release binaries already built
#   POMO_VERSION=0.1.0 scripts/bundle.sh
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/bundle.sh
#                                        sign for release (hardened runtime + timestamp); default is ad hoc
#   SPARKLE_PUBLIC_KEY=...               EdDSA public key for updates (required when SIGN_IDENTITY is set);
#                                        without it the app is built with the update check off
#                                        (print it with: generate_keys --account dev.hamardikan.pomo -p)
set -euo pipefail

# Swift needs full Xcode (SwiftUI macros); fail before the slow cargo build.
if [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]] || ! xcrun --find xcodebuild >/dev/null 2>&1; then
  echo "Pomo.app needs full Xcode (not just the Command Line Tools): install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(dirname "$HERE")"
REPO="$(cd "$PKG/../.." && pwd)"
OUT="${1:-$PKG/.build/bundle}"
VERSION="${POMO_VERSION:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"
if [[ -n "$SIGN_IDENTITY" && -z "$SPARKLE_PUBLIC_KEY" ]]; then
  echo "set SPARKLE_PUBLIC_KEY (generate_keys --account dev.hamardikan.pomo -p) when SIGN_IDENTITY is set" >&2
  exit 1
fi
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/pomo-target/mac}"

# A release waiting on Apple notarizes this exact build; rebuilding would orphan it.
for s in "$OUT"/release-*/app.id; do
  [[ -e "$s" && ! -e "$(dirname "$s")/released" ]] || continue
  [[ "${FORCE:-}" == 1 ]] || { echo "a release is in progress ($(dirname "$s")); finish it or rerun with FORCE=1" >&2; exit 1; }
done

if [[ "${SKIP_RUST:-0}" == "0" ]]; then
  (cd "$REPO" && cargo build --release -p pomod -p pomo-cli)
fi
for b in pomod pomo; do
  [[ -x "$CARGO_TARGET_DIR/release/$b" ]] || { echo "missing $CARGO_TARGET_DIR/release/$b" >&2; exit 1; }
done

(cd "$PKG" && swift build -c release)
BINDIR="$(cd "$PKG" && swift build -c release --show-bin-path)"
BIN="$BINDIR/PomoMac"

APP="$OUT/Pomo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/PomoMac"
cp "$CARGO_TARGET_DIR/release/pomod" "$CARGO_TARGET_DIR/release/pomo" "$APP/Contents/Helpers/"
# Sparkle 2 goes in Contents/Frameworks, where the app's @executable_path/../Frameworks rpath looks.
ditto "$BINDIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# Regenerate with `swift apple/scripts/make-icons.swift`.
cp "$PKG/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

SPARKLE_KEYS=""
if [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then
  SPARKLE_KEYS="  <key>SUFeedURL</key><string>https://github.com/hmrdkn-labs/pomo/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.hamardikan.pomo</string>
  <key>CFBundleName</key><string>Pomo</string>
  <key>CFBundleDisplayName</key><string>Pomo</string>
  <key>CFBundleExecutable</key><string>PomoMac</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
$SPARKLE_KEYS
</dict>
</plist>
PLIST

if [[ -n "$SIGN_IDENTITY" ]]; then
  # Hardened runtime + secure timestamp are required for notarization. Sign inside-out, no --deep.
  sign() { codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@"; }
  sign --identifier dev.hamardikan.pomo.pomod "$APP/Contents/Helpers/pomod"
  sign --identifier dev.hamardikan.pomo.cli "$APP/Contents/Helpers/pomo"
  # Sparkle's own code, inside-out, as its docs prescribe (sparkle-project.org/documentation/sandboxing/#code-signing).
  SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  for x in "$SP"/XPCServices/*.xpc; do
    [[ -e "$x" ]] || continue
    sign --preserve-metadata=entitlements "$x"
  done
  sign "$SP/Autoupdate"
  sign "$SP/Updater.app"
  sign "$APP/Contents/Frameworks/Sparkle.framework"
  sign --identifier dev.hamardikan.pomo "$APP"
else
  # Ad hoc: helpers first, then the bundle.
  codesign --force --sign - "$APP/Contents/Helpers/pomod"
  codesign --force --sign - "$APP/Contents/Helpers/pomo"
  codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework"
  codesign --force --sign - --identifier dev.hamardikan.pomo "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "$APP"
