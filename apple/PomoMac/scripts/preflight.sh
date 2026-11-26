#!/bin/sh
# Release checklist for ".build/bundle/Pomo.app". Run before every notarization submit; exits non-zero on any failure.
set -eu
cd "$(dirname "$0")/.."
A=".build/bundle/Pomo.app"
fail() { echo "PREFLIGHT FAIL: $1" >&2; exit 1; }

swift test >/dev/null 2>&1 || fail "unit tests"
plutil -lint "$A/Contents/Info.plist" >/dev/null || fail "plist lint"
codesign --verify --deep --strict "$A" 2>/dev/null || fail "codesign verify"
for B in "$A/Contents/MacOS/PomoMac" "$A/Contents/Helpers/pomod" "$A/Contents/Helpers/pomo"; do
  f=$(basename "$B")
  [ -x "$B" ] || fail "$f missing"
  I=$(codesign -dvv "$B" 2>&1)
  echo "$I" | grep -q 'Authority=Developer ID Application' || fail "$f not signed with Developer ID"
  echo "$I" | grep -q 'flags=0x10000(runtime)' || fail "$f missing hardened runtime"
  echo "$I" | grep -q '^Timestamp=' || fail "$f missing secure timestamp"
  codesign -d --entitlements - "$B" 2>&1 | grep -q get-task-allow && fail "$f has get-task-allow"
  lipo -archs "$B" | grep -q arm64 || fail "$f lacks arm64"
done
[ -d "$A/Contents/Frameworks/Sparkle.framework" ] || fail "Sparkle.framework missing"
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$A/Contents/Info.plist" >/dev/null 2>&1 || fail "SUPublicEDKey missing (set SPARKLE_PUBLIC_KEY for bundle.sh)"
echo "preflight ok"
