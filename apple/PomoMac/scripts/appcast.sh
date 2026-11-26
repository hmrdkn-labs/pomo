#!/bin/sh
# Adds or replaces this version's <item> in the Sparkle appcast, the feed the app checks for updates.
#   scripts/appcast.sh <version> <dmg> [appcast.xml]
# Run once the DMG is final (stapled); release.sh then attaches the feed to the v<version> release, which the app
# reads at releases/latest/download/appcast.xml. Start from the previous release's feed to keep its items.
# The app inside the DMG must be this version; its CFBundleVersion is the Sparkle build number.
# The DMG is signed with the EdDSA private key exported to ~/.private_keys/sparkle_ed25519 (or $SPARKLE_KEY);
# its public half is SUPublicEDKey in the app Info.plist (bundle.sh, from SPARKLE_PUBLIC_KEY).
set -eu
cd "$(dirname "$0")/.."
VERSION=${1:?usage: scripts/appcast.sh <version> <dmg> [appcast.xml]}
DMG=${2:?usage: scripts/appcast.sh <version> <dmg> [appcast.xml]}
OUT=${3:-.build/bundle/appcast.xml}
REPO="${REPO:-hmrdkn-labs/pomo}"
SIGN=.build/artifacts/sparkle/Sparkle/bin/sign_update  # in this package's .build after swift build
KEY="${SPARKLE_KEY:-$HOME/.private_keys/sparkle_ed25519}"
[ -f "$KEY" ] || { echo "Sparkle EdDSA private key not found: $KEY (export it with generate_keys -x, or set SPARKLE_KEY)" >&2; exit 1; }
[ -x "$SIGN" ] || { echo "$SIGN missing: run swift package resolve" >&2; exit 1; }
[ -f "$DMG" ] || { echo "no such DMG: $DMG" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/appcast.XXXXXX")
MNT=$(mktemp -d "${TMPDIR:-/tmp}/appcast-mnt.XXXXXX")
cleanup() {
  hdiutil detach -quiet "$MNT" >/dev/null 2>&1 || true
  rmdir "$MNT" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MNT" "$DMG" >/dev/null
set -- "$MNT"/*.app
[ "$#" = 1 ] && [ -d "$1" ] || { echo "$DMG must contain exactly one .app" >&2; exit 1; }
INFO="$1/Contents/Info.plist"
SHORT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")
MINOS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO")
[ "$SHORT" = "$VERSION" ] || { echo "the app in $DMG is $SHORT, not $VERSION" >&2; exit 1; }

LEN=$(stat -f %z "$DMG")
SIG=$("$SIGN" -p --ed-key-file "$KEY" "$DMG")
[ -n "$SIG" ] || { echo "sign_update printed no signature" >&2; exit 1; }
PUBDATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')

ITEM="$WORK/item.xml"
cat > "$ITEM" <<EOF
    <item>
      <title>Pomo $VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINOS</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/Pomo-$VERSION.dmg" length="$LEN" type="application/octet-stream" sparkle:edSignature="$SIG"/>
    </item>
EOF

if [ ! -e "$OUT" ]; then
  cat > "$OUT" <<EOF
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Pomo</title>
    <link>https://github.com/$REPO</link>
    <description>Pomo releases</description>
    <language>en</language>
  </channel>
</rss>
EOF
fi

# Copy the feed, dropping any item for this version and putting the new one first (newest first).
TMP="$WORK/appcast.xml"
awk -v item="$ITEM" -v ver="$VERSION" '
  function emit(    line) { while ((getline line < item) > 0) print line; close(item); placed = 1 }
  /^ *<item>/ && !inblock { if (!placed) emit(); inblock = 1; block = "" }
  inblock {
    block = block $0 "\n"
    if ($0 ~ /<\/item>/) {
      inblock = 0
      if (index(block, "<sparkle:shortVersionString>" ver "</sparkle:shortVersionString>") == 0) printf "%s", block
    }
    next
  }
  /<\/channel>/ && !placed { emit() }
  { print }
' "$OUT" > "$TMP"
xmllint --noout "$TMP"
grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$TMP" \
  || { echo "item for $VERSION not written; is there a <channel>?" >&2; exit 1; }
mv "$TMP" "$OUT"
echo "$OUT: v$VERSION (build $BUILD, $LEN bytes)"
