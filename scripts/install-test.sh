#!/usr/bin/env bash
# Sandboxed checks for install.sh / uninstall.sh — fake HOME, no network, no
# launchd.
#
# HOOKLINE_SANDBOX=1 keeps both scripts off global paths (/usr/local/bin) and
# away from launchctl. Asserts the install/uninstall registration pairs invert
# exactly (settings JSON byte-identical after round trip, other hooks
# untouched), the plugin file appears/disappears, plists are written and
# removed, the topic survives reinstall, and config/log removal is opt-in.
#
# Usage: bash scripts/install-test.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

CLEANUP_DIRS=()
cleanup() {
  for d in "${CLEANUP_DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done
}
trap cleanup EXIT

sandbox="$(mktemp -d /tmp/hookline-install.XXXXXX)"
CLEANUP_DIRS+=("$sandbox")
H="$sandbox/home"
SETTINGS="$H/.claude/settings.json"
SETTINGS_BB="$H/.claude-bb/settings.json"
HOOK_DST="$H/.local/share/hookline/hooks/hookline.sh"
CLI_DST="$H/.local/bin/hookline"
PLUGIN_DST="$H/.config/opencode/plugins/hookline.js"
DAEMON_PLIST="$H/Library/LaunchAgents/com.hookline.daemon.plist"
WATCHDOG_PLIST="$H/Library/LaunchAgents/com.hookline.watchdog.plist"
CONFIG="$H/.config/hookline/config"

mkdir -p "$H/.claude" "$H/.claude-bb" "$H/.config/opencode" "$H/.config/hookline" \
         "$H/Library/LaunchAgents"

seed_settings() { # seed_settings <path>
  cat > "$1" <<'EOF'
{
  "model": "opus",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [{ "type": "command", "command": "/opt/bin/other-hook", "timeout": 100 }]
      }
    ]
  }
}
EOF
}
seed_settings "$SETTINGS"
seed_settings "$SETTINGS_BB"
seed_a="$(jq -S . "$SETTINGS")"
seed_b="$(jq -S . "$SETTINGS_BB")"

# Pre-written config keeps install non-interactive (topic must survive).
printf '%s\n' 'HOOKLINE_TOPIC="install-test-topic"' > "$CONFIG"

expect_rc() { # expect_rc <name> <rc>
  if [ "$2" -eq 0 ]; then echo "PASS $1 rc=0"; PASS=$((PASS + 1))
  else echo "FAIL $1 rc=$2"; FAIL=$((FAIL + 1)); fi
}

expect_eq() { # expect_eq <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "PASS $1"; PASS=$((PASS + 1))
  else echo "FAIL $1"; FAIL=$((FAIL + 1)); fi
}

contains() { # contains <name> <haystack> <needle>
  case "$2" in
    *"$3"*) echo "PASS $1"; PASS=$((PASS + 1)) ;;
    *) echo "FAIL $1 — missing: $3"; FAIL=$((FAIL + 1)) ;;
  esac
}

absent() { # absent <name> <haystack> <needle>
  case "$2" in
    *"$3"*) echo "FAIL $1 — unexpectedly contains: $3"; FAIL=$((FAIL + 1)) ;;
    *) echo "PASS $1"; PASS=$((PASS + 1)) ;;
  esac
}

exists() { # exists <name> <path>
  if [ -e "$2" ]; then echo "PASS $1"; PASS=$((PASS + 1))
  else echo "FAIL $1 — missing file: $2"; FAIL=$((FAIL + 1)); fi
}

not_exists() { # not_exists <name> <path>
  if [ -e "$2" ]; then echo "FAIL $1 — file still present: $2"; FAIL=$((FAIL + 1))
  else echo "PASS $1"; PASS=$((PASS + 1)); fi
}

hookline_count() { # hookline_count <settings> -> number of hookline hook commands
  jq '[.hooks.PreToolUse[]?.hooks[]? | select((.command // "") | contains("hookline"))] | length' "$1"
}

other_hook_count() { # <settings> -> number of /opt/bin/other-hook commands
  jq '[.hooks.PreToolUse[]?.hooks[]? | select((.command // "") | contains("other-hook"))] | length' "$1"
}

run_install() {
  env HOME="$H" HOOKLINE_SANDBOX=1 bash "$REPO/install.sh" 2>&1
}

run_uninstall() { # run_uninstall <y|n>
  printf '%s\n' "$1" | env HOME="$H" HOOKLINE_SANDBOX=1 bash "$REPO/uninstall.sh" 2>&1
}

# ── 1. fresh install: files land, registration added, launchd skipped ──
out="$(run_install)"
rc=$?
expect_rc "install" "$rc"
contains "install-skips-launchd" "$out" "launchd registration skipped"
absent "install-no-launchd-claim" "$out" "Daemon registered with launchd"
exists "hook-installed" "$HOOK_DST"
exists "cli-installed" "$CLI_DST"
exists "daemon-plist-written" "$DAEMON_PLIST"
exists "watchdog-plist-written" "$WATCHDOG_PLIST"
exists "watchdog-py-written" "$H/.local/share/hookline/watchdog.py"
exists "plugin-installed" "$PLUGIN_DST"
contains "topic-preserved" "$(cat "$CONFIG")" 'HOOKLINE_TOPIC="install-test-topic"'
contains "plist-resolves-cli-path" "$(cat "$DAEMON_PLIST")" "$CLI_DST"
absent "plist-no-placeholder" "$(cat "$DAEMON_PLIST")" "HOOKLINE_DAEMON_PATH"
contains "registered-claude" "$(hookline_count "$SETTINGS")" "1"
contains "registered-blackbox" "$(hookline_count "$SETTINGS_BB")" "1"
contains "other-hook-kept" "$(other_hook_count "$SETTINGS")" "1"

# ── 2. reinstall is idempotent: one registration, topic unchanged ──
out="$(run_install)"
rc=$?
expect_rc "reinstall" "$rc"
contains "reinstall-already-registered" "$out" "already registered"
contains "reinstall-single-registration" "$(hookline_count "$SETTINGS")" "1"
contains "reinstall-topic-unchanged" "$(cat "$CONFIG")" 'HOOKLINE_TOPIC="install-test-topic"'

# ── 3. uninstall (keep config): exact inverse, other hooks untouched ──
out="$(run_uninstall n)"
rc=$?
expect_rc "uninstall-n" "$rc"
not_exists "hooks-removed" "$H/.local/share/hookline/hooks"
not_exists "cli-removed" "$CLI_DST"
not_exists "daemon-plist-removed" "$DAEMON_PLIST"
not_exists "watchdog-plist-removed" "$WATCHDOG_PLIST"
not_exists "watchdog-py-removed" "$H/.local/share/hookline/watchdog.py"
not_exists "plugin-removed" "$PLUGIN_DST"
contains "claude-registration-removed" "$(hookline_count "$SETTINGS")" "0"
contains "blackbox-registration-removed" "$(hookline_count "$SETTINGS_BB")" "0"
expect_eq "settings-json-roundtrip-claude" "$seed_a" "$(jq -S . "$SETTINGS")"
expect_eq "settings-json-roundtrip-blackbox" "$seed_b" "$(jq -S . "$SETTINGS_BB")"
exists "config-kept-on-n" "$CONFIG"

# ── 4. re-install after uninstall registers again (invert is re-runnable) ──
out="$(run_install)"
contains "re-register-after-uninstall" "$(hookline_count "$SETTINGS")" "1"

# ── 5. uninstall (remove config): everything goes ──
out="$(run_uninstall y)"
rc=$?
expect_rc "uninstall-y" "$rc"
not_exists "config-removed-on-y" "$CONFIG"
not_exists "config-dir-removed-on-y" "$H/.config/hookline"
not_exists "share-dir-removed-on-y" "$H/.local/share/hookline"

echo
echo "install-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
