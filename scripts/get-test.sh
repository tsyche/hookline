#!/usr/bin/env bash
# Sandboxed checks for get.sh (one-line install bootstrap) — fake HOME, no
# network, no launchd.
#
# Builds a release-style tarball from the working tree (GitHub layout:
# hookline-<tag>/...) and serves it through file:// URLs, so the whole
# download → extract → install.sh path runs offline. HOOKLINE_SANDBOX=1 keeps
# launchctl and /usr/local/bin untouched.
#
# Usage: bash scripts/get-test.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
GET="$REPO/get.sh"
PASS=0
FAIL=0

CLEANUP_DIRS=()
cleanup() {
  for d in "${CLEANUP_DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done
}
trap cleanup EXIT

[ -f "$GET" ] || { echo "get.sh not found: $GET"; exit 1; }

# ── fixture: GitHub-style release tarballs from the working tree ──
arc="$(mktemp -d /tmp/hookline-get.XXXXXX)"
CLEANUP_DIRS+=("$arc")
mkdir -p "$arc/dist"

make_tarball() { # make_tarball <tag-without-v>
  local tag="$1" stage="$arc/stage/hookline-$1"
  mkdir -p "$stage"
  (cd "$REPO" && tar -cf - --exclude .git .) | tar -xf - -C "$stage"
  tar -czf "$arc/dist/v${tag}.tar.gz" -C "$arc/stage" "hookline-${tag}"
}
make_tarball "9.9.9"
make_tarball "1.2.3"

printf '{"tag_name":"v9.9.9"}' > "$arc/dist/latest.json"

new_home() { # new_home -> echoes path
  local h
  h=$(mktemp -d /tmp/hookline-gethome.XXXXXX)
  CLEANUP_DIRS+=("$h")
  mkdir -p "$h/.claude"
  printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"/x/other-hook"}]}]}}' \
    > "$h/.claude/settings.json"
  echo "$h"
}

# run_get <home> <extra-env ...> — stdin at /dev/null (no prompt), captures
# combined output in $out and rc in $rc. Pins HOOKLINE_INIT_SYSTEM=launchd for
# determinism on macOS and Linux CI (later args in "$@" override it).
run_get() {
  local home="$1"; shift
  out=$(env HOME="$home" HOOKLINE_SANDBOX=1 HOOKLINE_INIT_SYSTEM=launchd \
      HOOKLINE_TARBALL_BASE="file://${arc}/dist" \
      HOOKLINE_LATEST_RELEASE_URL="file://${arc}/dist/latest.json" \
      "$@" bash "$GET" </dev/null 2>&1)
  rc=$?
}

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; while IFS= read -r l; do echo "  | $l"; done <<< "$out"; FAIL=$((FAIL + 1)); }

check() { # check <name> <condition-result 0/1>
  if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1"; fi
}

# ── 1. latest-release resolution → files land, topic auto-generated ──
h=$(new_home)
run_get "$h"
ok=0
[ "$rc" -eq 0 ] || ok=1
case "$out" in *"hookline v9.9.9: downloading"*) ;; *) ok=1 ;; esac
check "latest-release-install" "$ok"
ok=0
[ -f "$h/.local/share/hookline/hooks/hookline.sh" ] && [ -f "$h/.local/share/hookline/daemon/hookline-daemon" ] || ok=1
check "latest-release-files" "$ok"
grep -q "hookline-" "$h/.config/hookline/config" 2>/dev/null; rc2=$?
[ "$rc2" -eq 0 ] && grep -q 'HOOKLINE_TOPIC="hookline-' "$h/.config/hookline/config"
check "topic-auto-generated-on-eof" $?
ok=0
[ "$(cat "$h/.local/share/hookline/VERSION" 2>/dev/null)" = "$(cat "$REPO/VERSION")" ] || ok=1
check "version-file-recorded" "$ok"
grep -q "hookline" "$h/.claude/settings.json"; check "settings-registered" $?

# ── 2. HOOKLINE_VERSION pins the tarball, latest endpoint unused ──
h=$(new_home)
run_get "$h" HOOKLINE_VERSION=1.2.3 HOOKLINE_LATEST_RELEASE_URL="file://${arc}/dist/no-such.json"
ok=0
[ "$rc" -eq 0 ] || ok=1
case "$out" in *"hookline v1.2.3: downloading"*) ;; *) ok=1 ;; esac
case "$out" in *"v9.9.9"*) ok=1 ;; esac
check "version-pin" "$ok"

# ── 3. v-prefix normalization: HOOKLINE_VERSION=v1.2.3 → same tarball ──
h=$(new_home)
run_get "$h" HOOKLINE_VERSION=v1.2.3
ok=0
[ "$rc" -eq 0 ] || ok=1
case "$out" in *"hookline v1.2.3: downloading"*) ;; *) ok=1 ;; esac
check "version-v-prefix-normalized" "$ok"

# ── 4. missing tarball → nonzero rc, nothing installed ──
h=$(new_home)
run_get "$h" HOOKLINE_VERSION=7.7.7
ok=0
[ "$rc" -ne 0 ] || ok=1
check "missing-tarball-rc" "$ok"
ok=0
[ ! -f "$h/.config/hookline/config" ] || ok=1
check "missing-tarball-no-config" "$ok"

# ── 5. unresolvable latest release → explicit error, nothing installed ──
h=$(new_home)
run_get "$h" HOOKLINE_LATEST_RELEASE_URL="file://${arc}/dist/no-such.json"
ok=0
[ "$rc" -ne 0 ] || ok=1
case "$out" in *"could not determine the latest release"*) ;; *) ok=1 ;; esac
[ -f "$h/.config/hookline/config" ] && ok=1
check "latest-unresolvable-error" "$ok"

# ── 6. unsupported platform without sandbox → fail fast before any work ──
# HOOKLINE_INIT_SYSTEM pins "none" on every host (macOS and Linux CI each
# have their own init system, so OSTYPE alone is not enough).
h=$(new_home)
out=$(env HOME="$h" OSTYPE=linux-gnu HOOKLINE_INIT_SYSTEM=none \
    HOOKLINE_TARBALL_BASE="file://${arc}/dist" \
    bash "$GET" </dev/null 2>&1); rc=$?
ok=0
[ "$rc" -ne 0 ] || ok=1
case "$out" in *"supports macOS or Linux with systemd"*) ;; *) ok=1 ;; esac
[ -f "$h/.local/share/hookline/hooks/hookline.sh" ] && ok=1
check "linux-fail-fast" "$ok"

# ── 7. systemd (sandbox): bootstrap installs the unit layout ──
h=$(new_home)
run_get "$h" HOOKLINE_INIT_SYSTEM=systemd
ok=0
[ "$rc" -eq 0 ] || ok=1
[ -f "$h/.config/systemd/user/hookline-daemon.service" ] || ok=1
[ -f "$h/.config/systemd/user/hookline-watchdog.service" ] || ok=1
[ -f "$h/.config/systemd/user/hookline-watchdog.timer" ] || ok=1
[ -f "$h/Library/LaunchAgents/com.hookline.daemon.plist" ] && ok=1
grep -q "hookline" "$h/.claude/settings.json" || ok=1
check "systemd-install" "$ok"

echo
echo "get-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
