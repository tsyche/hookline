#!/usr/bin/env bash
# Assert the latest GitHub release tag matches VERSION and points at main.
#
# The release workflow (paths: [VERSION]) is now the only release path;
# this catches it silently failing, tagging the wrong version, or tagging a
# commit that isn't on main. Run post-push (CI job after the release
# workflow) or locally with gh auth.
#
# Usage: bash scripts/release-smoke.sh   (or: just release-smoke)
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
want="v$(tr -d '[:space:]' < "$REPO/VERSION")"

if ! command -v gh >/dev/null 2>&1; then
  echo "release-smoke: FAIL — gh not found" >&2
  exit 1
fi

if ! latest="$(gh release view --json tagName -q '.tagName' 2>&1)"; then
  echo "release-smoke: FAIL — cannot read latest release: ${latest}" >&2
  exit 1
fi

if [ "$latest" != "$want" ]; then
  echo "release-smoke: FAIL — latest release tag '${latest}' != VERSION '${want}'" >&2
  exit 1
fi

# The release must target a commit on main whose VERSION equals the tag —
# tag==VERSION alone misses a release tagging the wrong commit.
if ! target="$(gh release view --json targetCommitish -q '.targetCommitish' 2>&1)"; then
  echo "release-smoke: FAIL — cannot read release target: ${target}" >&2
  exit 1
fi

if ! git -C "$REPO" cat-file -e "${target}^{commit}" 2>/dev/null; then
  echo "release-smoke: FAIL — release target '${target}' not present locally (fetch main first)" >&2
  exit 1
fi

if ! git -C "$REPO" merge-base --is-ancestor "$target" HEAD 2>/dev/null; then
  echo "release-smoke: FAIL — release target '${target}' is not an ancestor of HEAD (not on main)" >&2
  exit 1
fi

if ! target_version="$(git -C "$REPO" show "${target}:VERSION" 2>/dev/null | tr -d '[:space:]')"; then
  echo "release-smoke: FAIL — cannot read VERSION at release target '${target}'" >&2
  exit 1
fi

if [ "v${target_version}" != "$latest" ]; then
  echo "release-smoke: FAIL — release target '${target}' has VERSION=${target_version}, tag is '${latest}'" >&2
  exit 1
fi

echo "release-smoke: ok — ${latest} matches VERSION and targets main@${target}"
