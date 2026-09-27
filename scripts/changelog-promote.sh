#!/bin/bash
# Promote CHANGELOG.md's [Unreleased] section into an entry for the current
# VERSION, and fix up the link footer. Idempotent — exits 0 when the version
# entry already exists. Run right after bumping VERSION (it targets VERSION's
# current value) so the changelog entry and the release tag land in the
# same push.
set -euo pipefail
cd "$(dirname "$0")/.."

CHANGELOG="CHANGELOG.md"
VERSION=$(tr -d '[:space:]' < VERSION)
[ -f "$CHANGELOG" ] || { echo "no CHANGELOG.md"; exit 1; }

if grep -q "^## \[${VERSION}\]" "$CHANGELOG"; then
  echo "CHANGELOG.md already has [${VERSION}]"
  exit 0
fi

# Previous release = newest version heading already in the file.
PREV=$(grep -m1 -E '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$CHANGELOG" | sed -E 's/^## \[([^]]+)\].*/\1/')
DATE=$(date +%F)

awk -v ver="$VERSION" -v date="$DATE" -v prev="$PREV" '
  { lines[NR] = $0 }
  END {
    for (i = 1; i <= NR; i++) {
      if (lines[i] ~ /^\[Unreleased\]:/) {
        printf "[Unreleased]: https://github.com/tsyche/hookline/compare/v%s...HEAD\n", ver
        printf "[%s]: https://github.com/tsyche/hookline/compare/v%s...v%s\n", ver, prev, ver
        continue
      }
      print lines[i]
      if (lines[i] == "## [Unreleased]") {
        print ""
        printf "## [%s] - %s\n", ver, date
        if (i + 1 <= NR && lines[i + 1] == "") i++   # absorb one blank, then re-add one
        print ""
      }
    }
  }
' "$CHANGELOG" > "${CHANGELOG}.tmp" && mv "${CHANGELOG}.tmp" "$CHANGELOG"

echo "CHANGELOG.md: [Unreleased] promoted to [${VERSION}] (${DATE})"
