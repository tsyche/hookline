#!/bin/bash
# get.sh — one-line installer bootstrap: downloads the hookline release
# tarball (no git checkout required) and runs install.sh from it.
#
#   curl -fsSL https://raw.githubusercontent.com/tsyche/hookline/main/get.sh | bash
#
# Env:
#   HOOKLINE_VERSION          release tag to install (default: latest GitHub release)
#   HOOKLINE_LATEST_RELEASE_URL  latest-release JSON endpoint override (tests)
#   HOOKLINE_TARBALL_BASE       tarball URL prefix override (tests)
#   HOOKLINE_SANDBOX=1          non-interactive install (no topic prompt)
set -euo pipefail

REPO_SLUG="tsyche/hookline"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fail fast off macOS before any network or filesystem work — launchd
# registration and osascript keystroke injection are macOS-only (Linux
# support is tracked in ROADMAP Phase 9). HOOKLINE_SANDBOX=1 keeps the
# Linux CI install tests running.
if [[ "${OSTYPE:-}" != darwin* ]] && [[ "${HOOKLINE_SANDBOX:-0}" != "1" ]]; then
  echo "Error: hookline supports macOS only (Linux support is tracked in ROADMAP.md Phase 9)." >&2
  echo "Nothing was installed." >&2
  exit 1
fi

for cmd in curl tar; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: $cmd is required." >&2; exit 1; }
done

tag="${HOOKLINE_VERSION:-}"
if [ -z "$tag" ]; then
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required to resolve the latest release (or set HOOKLINE_VERSION=vX.Y.Z)." >&2
    exit 1
  }
  api="${HOOKLINE_LATEST_RELEASE_URL:-https://api.github.com/repos/${REPO_SLUG}/releases/latest}"
  tag="$(curl -fsSL --max-time 10 -H "Accept: application/vnd.github+json" "$api" 2>/dev/null \
    | jq -r '.tag_name // empty' 2>/dev/null || true)"
  [ -n "$tag" ] || {
    echo "Error: could not determine the latest release (set HOOKLINE_VERSION=vX.Y.Z)." >&2
    exit 1
  }
fi
tag="v${tag#v}"

base="${HOOKLINE_TARBALL_BASE:-https://github.com/${REPO_SLUG}/archive/refs/tags}"
url="${base%/}/${tag}.tar.gz"

echo "hookline ${tag}: downloading ${url}"
curl -fsSL --max-time 60 "$url" -o "$TMP/hookline.tgz"
tar -xzf "$TMP/hookline.tgz" -C "$TMP"

install_sh="$(find "$TMP" -maxdepth 2 -name install.sh -type f | head -n 1)"
[ -n "$install_sh" ] || { echo "Error: no install.sh in the downloaded archive." >&2; exit 1; }

# install.sh prompts for a topic on stdin; under `curl | bash` stdin is the
# script pipe, so hand it the terminal instead (fall back to /dev/null →
# auto-generated topic). HOOKLINE_SANDBOX=1 forces the non-interactive path
# so tests never block on /dev/tty.
if [ "${HOOKLINE_SANDBOX:-0}" = "1" ]; then
  bash "$install_sh" </dev/null
elif [ -t 0 ]; then
  bash "$install_sh"
elif { : </dev/tty; } 2>/dev/null; then
  bash "$install_sh" </dev/tty
else
  bash "$install_sh" </dev/null
fi
