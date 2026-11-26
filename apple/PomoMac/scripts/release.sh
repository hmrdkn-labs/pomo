#!/bin/sh
# Notarize and publish a release without waiting on Apple: each run moves one step forward and exits.
#   1. preflight + submit the app         4. submit the DMG
#   2. (Apple accepts) staple the app     5. (Apple accepts) staple the DMG
#   3. build and sign the DMG             6. publish the GitHub release
# Run it until it prints "released", or let launchd run it every 5 minutes:
#   scripts/release.sh --schedule      (the job removes itself when done or when Apple rejects)
# Build first: SIGN_IDENTITY=... POMO_VERSION=x.y.z scripts/bundle.sh
#   SIGN_IDENTITY  Developer ID Application identity (required)
#   VERSION        must match the bundle (default: read from the built app)
#   NOTARY_PROFILE notarytool keychain profile (default pomo)
#   REPO           GitHub repo (default hmrdkn-labs/pomo)
set -eu
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
APP=".build/bundle/Pomo.app"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY}"
VERSION="${VERSION:-$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)}"
PROFILE="${NOTARY_PROFILE:-pomo}"
REPO="${REPO:-hmrdkn-labs/pomo}"
DMG=".build/bundle/Pomo-$VERSION.dmg"
STATE=".build/bundle/release-$VERSION"
JOB="dev.hamardikan.pomo.release"
PLIST="$HOME/Library/LaunchAgents/$JOB.plist"
mkdir -p "$STATE"

log() { echo "$(date '+%F %T') $*"; }
notify() { osascript -e "display notification \"$1\" with title \"Pomo release\"" 2>/dev/null || true; log "$1"; }
# Plist first: when the job unschedules itself, bootout ends this very script.
unschedule() { rm -f "$PLIST"; launchctl bootout "gui/$(id -u)/$JOB" 2>/dev/null || true; }

if [ "${1:-}" = "--schedule" ]; then
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$JOB</string>
  <key>ProgramArguments</key><array><string>/bin/sh</string><string>$PWD/scripts/release.sh</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>SIGN_IDENTITY</key><string>$SIGN_IDENTITY</string>
    <key>VERSION</key><string>$VERSION</string>
    <key>NOTARY_PROFILE</key><string>$PROFILE</string>
    <key>REPO</key><string>$REPO</string>
  </dict>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$PWD/$STATE/log</string>
  <key>StandardErrorPath</key><string>$PWD/$STATE/log</string>
</dict></plist>
EOF
  launchctl bootout "gui/$(id -u)/$JOB" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "scheduled; log: $STATE/log"
  exit 0
fi

if [ -e "$STATE/released" ]; then
  echo "v$VERSION is already released"
  unschedule
  exit 0
fi

# Prints Accepted / In Progress / Invalid / Rejected, or nothing if Apple can't be asked right now
# (offline, locked keychain); then the next run tries again.
status() {
  xcrun notarytool info "$1" --keychain-profile "$PROFILE" 2>/dev/null | sed -n 's/^ *status: //p' || true
}

# Waits for submission $1 (read from $2); returns 0 when accepted, exits otherwise.
gate() {
  s=$(status "$(cat "$2")")
  case "$s" in
    Accepted) return 0 ;;
    Invalid|Rejected)
      notify "Apple rejected the $1 ($s). See $STATE/log."
      xcrun notarytool log "$(cat "$2")" --keychain-profile "$PROFILE" || true
      unschedule; exit 1 ;;
    *) log "$1: waiting for Apple (${s:-no answer})"; exit 0 ;;
  esac
}

submit() {  # file, id file
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --output-format json \
    | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' > "$2"
  [ -s "$2" ] || { rm -f "$2"; log "submit of $1 failed; will retry"; exit 0; }
  log "submitted $1 as $(cat "$2")"
}

if [ ! -s "$STATE/app.id" ]; then
  scripts/preflight.sh
  ditto -c -k --keepParent "$APP" "$STATE/app.zip"
  submit "$STATE/app.zip" "$STATE/app.id"
  exit 0
fi
gate "app" "$STATE/app.id"
xcrun stapler validate "$APP" >/dev/null 2>&1 || xcrun stapler staple "$APP"

if [ ! -s "$STATE/dmg.id" ]; then
  rm -rf .build/bundle/dmg "$DMG" && mkdir -p .build/bundle/dmg && cp -R "$APP" .build/bundle/dmg/ && ln -s /Applications .build/bundle/dmg/Applications
  hdiutil create -volname "Pomo" -srcfolder .build/bundle/dmg -ov -format UDZO "$DMG"
  rm -rf .build/bundle/dmg
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  submit "$DMG" "$STATE/dmg.id"
  exit 0
fi
gate "DMG" "$STATE/dmg.id"
xcrun stapler validate "$DMG" >/dev/null 2>&1 || xcrun stapler staple "$DMG"
spctl --assess --type execute "$APP"
spctl --assess --type open --context context:primary-signature "$DMG"

# Sparkle feed: the previous release's appcast plus this version, attached to this release. The app reads
# releases/latest/download/appcast.xml, so publishing the release is what offers the update.
FEED="$STATE/appcast.xml"
if [ ! -s "$FEED" ]; then
  gh release download --repo "$REPO" --pattern appcast.xml --output "$FEED" 2>/dev/null || rm -f "$FEED"
fi
scripts/appcast.sh "$VERSION" "$DMG" "$FEED"

if ! gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  # Notes: this version's CHANGELOG section, then how to install.
  # Headings look like "## [0.1.0] - date" (Keep a Changelog) or "## 0.1.0 ...".
  changes=$(awk -v a="## [$VERSION]" -v b="## $VERSION " 'index($0, a) == 1 || index($0, b) == 1 { on = 1; next } on && /^## / { exit } on' ../../CHANGELOG.md)
  [ -n "$changes" ] || { log "no CHANGELOG.md section (repo root) for $VERSION"; exit 1; }
  gh release create "v$VERSION" "$DMG" "$FEED" --repo "$REPO" --title "Pomo $VERSION" --notes-file - <<EOF
Pomo is a Pomodoro timer for the menu bar, with a CLI for you and your AI agents.
$changes

Open the DMG, drag Pomo to Applications, and open it, or \`brew install --cask hmrdkn-labs/tap/pomo\`.
Signed with Developer ID and notarized by Apple. Requires macOS 14 or later. Updates install themselves.
EOF
else
  gh release upload "v$VERSION" "$FEED" --repo "$REPO" --clobber
fi
scripts/update-cask.sh "$VERSION" "$DMG"
notify "Released v$VERSION: https://github.com/$REPO/releases/tag/v$VERSION"
rm -f "$STATE/app.zip"
touch "$STATE/released"
unschedule
echo released
