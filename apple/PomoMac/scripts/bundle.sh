#!/bin/bash
# Assemble Pomo.app (menu bar app) with embedded pomod and pomo, ad-hoc signed.
#
#   scripts/bundle.sh [output-dir]       default output: apple/PomoMac/.build/bundle
#   SKIP_RUST=1 scripts/bundle.sh        (0 or unset: build) reuse the release binaries already built
#   POMO_VERSION=0.1.0 scripts/bundle.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(dirname "$HERE")"
REPO="$(cd "$PKG/../.." && pwd)"
OUT="${1:-$PKG/.build/bundle}"
VERSION="${POMO_VERSION:-0.1.0}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/pomo-target/mac}"

if [[ "${SKIP_RUST:-0}" == "0" ]]; then
  (cd "$REPO" && cargo build --release -p pomod -p pomo-cli)
fi
for b in pomod pomo; do
  [[ -x "$CARGO_TARGET_DIR/release/$b" ]] || { echo "missing $CARGO_TARGET_DIR/release/$b" >&2; exit 1; }
done

(cd "$PKG" && swift build -c release)
BIN="$(cd "$PKG" && swift build -c release --show-bin-path)/PomoMac"

APP="$OUT/Pomo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PomoMac"
cp "$CARGO_TARGET_DIR/release/pomod" "$CARGO_TARGET_DIR/release/pomo" "$APP/Contents/Helpers/"
# Regenerate with `swift apple/scripts/make-icons.swift`.
cp "$PKG/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

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
</dict>
</plist>
PLIST

# Sign helpers first, then the bundle (ad-hoc).
codesign --force --sign - "$APP/Contents/Helpers/pomod"
codesign --force --sign - "$APP/Contents/Helpers/pomo"
codesign --force --sign - --identifier dev.hamardikan.pomo "$APP"
codesign --verify --strict "$APP"
echo "$APP"
