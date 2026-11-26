#!/bin/sh
# Point the Homebrew cask (hmrdkn-labs/homebrew-tap, Casks/pomo.rb) at a published release.
#   scripts/update-cask.sh <version> <dmg>
# Idempotent: does nothing if the cask already has this version and checksum. Uses the GitHub API, so it needs
# no local clone of the tap.
set -eu
VERSION="$1"
DMG="$2"
TAP="${TAP:-hmrdkn-labs/homebrew-tap}"
FILE="Casks/pomo.rb"

sha=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
current=$(gh api "repos/$TAP/contents/$FILE")
blob=$(printf '%s' "$current" | python3 -c 'import sys, json; print(json.load(sys.stdin)["sha"])')
old=$(printf '%s' "$current" | python3 -c 'import sys, json, base64; print(base64.b64decode(json.load(sys.stdin)["content"]).decode(), end="")')

new=$(printf '%s' "$old" | sed -e "s/^  version \".*\"$/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"$/  sha256 \"$sha\"/")
if [ "$new" = "$old" ]; then echo "cask already at $VERSION"; exit 0; fi

printf '%s\n' "$new" | base64 | tr -d '\n' > "${TMPDIR:-/tmp}/pomo-cask.b64"
gh api -X PUT "repos/$TAP/contents/$FILE" -f message="pomo $VERSION" -f sha="$blob" \
  -F content=@"${TMPDIR:-/tmp}/pomo-cask.b64" >/dev/null
rm -f "${TMPDIR:-/tmp}/pomo-cask.b64"
echo "cask updated to $VERSION"
