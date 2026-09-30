#!/usr/bin/env bash
# Sandboxed checks for install.sh / uninstall.sh — fake HOME, no network, no
# real init system (launchd or systemd).
#
# HOOKLINE_SANDBOX=1 keeps both scripts off global paths (/usr/local/bin) and
# away from launchctl/systemctl. Every run pins HOOKLINE_INIT_SYSTEM so the
# suite is deterministic on macOS and Linux CI alike. Asserts the
# install/uninstall registration pairs invert exactly (settings JSON
# byte-identical after round trip, other hooks untouched), the plugin file
# appears/disappears, the platform's job files (plist / systemd units) are
# written and removed, the topic survives reinstall, and config/log removal is
# opt-in.
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
CODEX_HOOKS="$H/.codex/hooks.json"

mkdir -p "$H/.claude" "$H/.claude-bb" "$H/.config/opencode" "$H/.config/hookline" \
         "$H/Library/LaunchAgents" "$H/.codex"

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

# Seed codex's own hooks file in jq's exact output format — the install/
# uninstall merge must preserve the foreign hook and restore the file (a
# round-trip against a hand-formatted file would only test jq's formatting).
cat > "$CODEX_HOOKS" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/opt/bin/foreign-hook"
          }
        ]
      }
    ]
  }
}
EOF
seed_cx="$(jq -S . "$CODEX_HOOKS")"

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

codex_count() { # <hooks.json> -> number of hookline PermissionRequest commands
  jq '[.hooks.PermissionRequest[]?.hooks[]? | select((.command // "") | contains("hookline"))] | length' "$1"
}

codex_foreign_count() { # <hooks.json> -> foreign SessionStart hooks that must survive
  jq '[.hooks.SessionStart[]?.hooks[]? | select((.command // "") | contains("foreign-hook"))] | length' "$1"
}

run_install() {
  env HOME="$H" HOOKLINE_SANDBOX=1 HOOKLINE_INIT_SYSTEM=launchd bash "$REPO/install.sh" 2>&1
}

run_uninstall() { # run_uninstall <y|n>
  printf '%s\n' "$1" | env HOME="$H" HOOKLINE_SANDBOX=1 HOOKLINE_INIT_SYSTEM=launchd bash "$REPO/uninstall.sh" 2>&1
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
exists "version-recorded" "$H/.local/share/hookline/VERSION"
contains "topic-preserved" "$(cat "$CONFIG")" 'HOOKLINE_TOPIC="install-test-topic"'
contains "plist-resolves-cli-path" "$(cat "$DAEMON_PLIST")" "$CLI_DST"
absent "plist-no-placeholder" "$(cat "$DAEMON_PLIST")" "HOOKLINE_DAEMON_PATH"
contains "registered-claude" "$(hookline_count "$SETTINGS")" "1"
contains "registered-blackbox" "$(hookline_count "$SETTINGS_BB")" "1"
contains "other-hook-kept" "$(other_hook_count "$SETTINGS")" "1"
contains "registered-codex" "$(codex_count "$CODEX_HOOKS")" "1"
contains "codex-foreign-hook-kept" "$(codex_foreign_count "$CODEX_HOOKS")" "1"
contains "codex-matcher-set" "$(jq -r '.hooks.PermissionRequest[0].matcher' "$CODEX_HOOKS")" "Bash|apply_patch|mcp__.*"
contains "install-mentions-codex-trust" "$out" "codex (/hooks)"

# ── 2. reinstall is idempotent: one registration, topic unchanged ──
out="$(run_install)"
rc=$?
expect_rc "reinstall" "$rc"
contains "reinstall-already-registered" "$out" "already registered"
contains "reinstall-single-registration" "$(hookline_count "$SETTINGS")" "1"
contains "reinstall-single-codex-registration" "$(codex_count "$CODEX_HOOKS")" "1"
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
not_exists "version-removed" "$H/.local/share/hookline/VERSION"
contains "claude-registration-removed" "$(hookline_count "$SETTINGS")" "0"
contains "blackbox-registration-removed" "$(hookline_count "$SETTINGS_BB")" "0"
contains "codex-registration-removed" "$(codex_count "$CODEX_HOOKS")" "0"
contains "codex-foreign-hook-survives" "$(codex_foreign_count "$CODEX_HOOKS")" "1"
expect_eq "hooks-json-roundtrip-codex" "$seed_cx" "$(jq -S . "$CODEX_HOOKS")"
expect_eq "settings-json-roundtrip-claude" "$seed_a" "$(jq -S . "$SETTINGS")"
expect_eq "settings-json-roundtrip-blackbox" "$seed_b" "$(jq -S . "$SETTINGS_BB")"
exists "config-kept-on-n" "$CONFIG"

# ── 4. re-install after uninstall registers again (invert is re-runnable) ──
out="$(run_install)"
contains "re-register-after-uninstall" "$(hookline_count "$SETTINGS")" "1"
contains "re-register-codex-after-uninstall" "$(codex_count "$CODEX_HOOKS")" "1"

# ── 5. uninstall (remove config): everything goes ──
out="$(run_uninstall y)"
rc=$?
expect_rc "uninstall-y" "$rc"
not_exists "config-removed-on-y" "$CONFIG"
not_exists "config-dir-removed-on-y" "$H/.config/hookline"
not_exists "share-dir-removed-on-y" "$H/.local/share/hookline"

# ── 6. unsupported platform without sandbox → fail fast before any write ──
# Separate fake HOME (leaves the round-trip state alone). HOOKLINE_INIT_SYSTEM
# pins "none" on every host (macOS and Linux CI each have their own init
# system, so OSTYPE alone is not enough), and launchctl/systemctl are stubbed
# so a regression in the guard can't touch the real init system.
lh="$sandbox/linux-home"
mkdir -p "$lh/.claude" "$lh/.config" "$lh/Library/LaunchAgents" \
         "$lh/.local/share/hookline" "$sandbox/stub-bin"
printf '#!/bin/bash\necho "launchctl CALLED" >&2\nexit 0\n' > "$sandbox/stub-bin/launchctl"
printf '#!/bin/bash\necho "systemctl CALLED" >&2\nexit 0\n' > "$sandbox/stub-bin/systemctl"
chmod +x "$sandbox/stub-bin/launchctl" "$sandbox/stub-bin/systemctl"
out="$(env HOME="$lh" OSTYPE=linux-gnu PATH="$sandbox/stub-bin:$PATH" HOOKLINE_SANDBOX=0 \
       HOOKLINE_INIT_SYSTEM=none bash "$REPO/install.sh" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then echo "PASS linux-guard-rc rc=$rc"; PASS=$((PASS + 1))
else echo "FAIL linux-guard-rc rc=0"; FAIL=$((FAIL + 1)); fi
contains "linux-guard-message" "$out" "supports macOS or Linux with systemd"
absent "linux-guard-launchctl-stub" "$out" "launchctl CALLED"
absent "linux-guard-systemctl-stub" "$out" "systemctl CALLED"
not_exists "linux-guard-no-config" "$lh/.config/hookline/config"
not_exists "linux-guard-no-plist" "$lh/Library/LaunchAgents/com.hookline.daemon.plist"
not_exists "linux-guard-no-hook" "$lh/.local/share/hookline/hooks/hookline.sh"

# ── 6b. unknown OSTYPE, no override → auto-detect falls through to none ──
# freebsd13 is never darwin/linux, so this exercises the detection fallback
# itself (not just the HOOKLINE_INIT_SYSTEM override path above).
fh="$sandbox/bsd-home"
mkdir -p "$fh/.claude" "$fh/.config"
out="$(env HOME="$fh" OSTYPE=freebsd13 HOOKLINE_INIT_SYSTEM= PATH="$sandbox/stub-bin:$PATH" \
       HOOKLINE_SANDBOX=0 bash "$REPO/install.sh" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then echo "PASS bsd-guard-rc rc=$rc"; PASS=$((PASS + 1))
else echo "FAIL bsd-guard-rc rc=0"; FAIL=$((FAIL + 1)); fi
contains "bsd-guard-message" "$out" "supports macOS or Linux with systemd"
not_exists "bsd-guard-no-config" "$fh/.config/hookline/config"

# ── 7. systemd (sandbox): unit files land, no plist, no systemctl call ──
sh="$sandbox/systemd-home"
mkdir -p "$sh/.claude" "$sh/.config/opencode" "$sh/.config/hookline" "$sh/.codex"
printf '%s\n' 'HOOKLINE_TOPIC="install-test-topic"' > "$sh/.config/hookline/config"
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"/x/other-hook"}]}]}}' \
  > "$sh/.claude/settings.json"
out="$(env HOME="$sh" HOOKLINE_SANDBOX=1 HOOKLINE_INIT_SYSTEM=systemd PATH="$sandbox/stub-bin:$PATH" \
       bash "$REPO/install.sh" 2>&1)"
rc=$?
expect_rc "systemd-sandbox-install" "$rc"
contains "systemd-skips-registration" "$out" "systemd registration skipped"
absent "systemd-no-systemctl-call" "$out" "systemctl CALLED"
exists "systemd-daemon-unit-written" "$sh/.config/systemd/user/hookline-daemon.service"
exists "systemd-watchdog-unit-written" "$sh/.config/systemd/user/hookline-watchdog.service"
exists "systemd-watchdog-timer-written" "$sh/.config/systemd/user/hookline-watchdog.timer"
exists "systemd-watchdog-py-written" "$sh/.local/share/hookline/watchdog.py"
exists "systemd-cli-installed" "$sh/.local/bin/hookline"
not_exists "systemd-no-plist-dir" "$sh/Library/LaunchAgents"
contains "unit-resolves-cli-path" "$(cat "$sh/.config/systemd/user/hookline-daemon.service")" "$sh/.local/bin/hookline"
absent "unit-no-placeholder" "$(cat "$sh/.config/systemd/user/hookline-daemon.service")" "HOOKLINE_DAEMON_PATH"
absent "timer-no-placeholder" "$(cat "$sh/.config/systemd/user/hookline-watchdog.timer")" "HOOKLINE_LOG_DIR"
contains "systemd-settings-registered" \
  "$(jq '[.hooks.PreToolUse[]?.hooks[]? | select((.command // "") | contains("hookline"))] | length' "$sh/.claude/settings.json")" "1"
out="$(printf 'n\n' | env HOME="$sh" HOOKLINE_SANDBOX=1 HOOKLINE_INIT_SYSTEM=systemd \
       PATH="$sandbox/stub-bin:$PATH" bash "$REPO/uninstall.sh" 2>&1)"
rc=$?
expect_rc "systemd-sandbox-uninstall" "$rc"
absent "systemd-uninstall-no-systemctl" "$out" "systemctl CALLED"
not_exists "systemd-daemon-unit-removed" "$sh/.config/systemd/user/hookline-daemon.service"
not_exists "systemd-watchdog-service-removed" "$sh/.config/systemd/user/hookline-watchdog.service"
not_exists "systemd-watchdog-timer-removed" "$sh/.config/systemd/user/hookline-watchdog.timer"
not_exists "systemd-cli-removed" "$sh/.local/bin/hookline"
not_exists "systemd-hooks-removed" "$sh/.local/share/hookline/hooks"
exists "systemd-config-kept-on-n" "$sh/.config/hookline/config"

# ── 8. systemd (non-sandbox): registration drives the user bus via stubs ──
# HOOKLINE_CLI_DIR points the CLI install at a sandbox path so a non-sandbox
# run never touches the real /usr/local/bin; systemctl/loginctl are stubbed
# first in PATH and log their argv for assertion.
ch="$sandbox/systemd-live-home"
cli="$sandbox/cli8/bin/hookline"
log="$sandbox/systemd8.log"
mkdir -p "$ch/.claude" "$ch/.config/opencode" "$ch/.config/hookline" "$ch/.codex" "$sandbox/stub-bin8"
printf '%s\n' 'HOOKLINE_TOPIC="install-test-topic"' > "$ch/.config/hookline/config"
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"/x/other-hook"}]}]}}' \
  > "$ch/.claude/settings.json"
cat > "$sandbox/stub-bin8/systemctl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$log"
exit 0
EOF
cat > "$sandbox/stub-bin8/loginctl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$log"
echo "no"
exit 0
EOF
chmod +x "$sandbox/stub-bin8/systemctl" "$sandbox/stub-bin8/loginctl"
out="$(env HOME="$ch" HOOKLINE_SANDBOX=0 HOOKLINE_INIT_SYSTEM=systemd \
       HOOKLINE_CLI_DIR="$cli" PATH="$sandbox/stub-bin8:$PATH" \
       bash "$REPO/install.sh" 2>&1)"
rc=$?
expect_rc "systemd-live-install" "$rc"
exists "systemd-live-daemon-unit" "$ch/.config/systemd/user/hookline-daemon.service"
exists "systemd-live-timer" "$ch/.config/systemd/user/hookline-watchdog.timer"
exists "systemd-live-cli-at-cli-dir" "$cli"
contains "systemd-live-cli-msg" "$out" "CLI installed to $cli"
contains "unit-execstart-cli-dir" "$(cat "$ch/.config/systemd/user/hookline-daemon.service")" "$cli"
contains "live-daemon-reload" "$(cat "$log")" "--user daemon-reload"
contains "live-daemon-enable" "$(cat "$log")" "--user enable --now hookline-daemon.service"
contains "live-timer-enable" "$(cat "$log")" "--user enable --now hookline-watchdog.timer"
contains "live-registered-claim" "$out" "Daemon registered with systemd"
contains "live-linger-note" "$out" "loginctl enable-linger"
contains "live-linger-probe" "$(cat "$log")" "show-user"
contains "live-settings-registered" \
  "$(jq '[.hooks.PreToolUse[]?.hooks[]? | select((.command // "") | contains("hookline"))] | length' "$ch/.claude/settings.json")" "1"

out="$(printf 'n\n' | env HOME="$ch" HOOKLINE_SANDBOX=0 HOOKLINE_INIT_SYSTEM=systemd \
       HOOKLINE_CLI_DIR="$cli" PATH="$sandbox/stub-bin8:$PATH" \
       bash "$REPO/uninstall.sh" 2>&1)"
rc=$?
expect_rc "systemd-live-uninstall" "$rc"
not_exists "systemd-live-unit-removed" "$ch/.config/systemd/user/hookline-daemon.service"
not_exists "systemd-live-timer-removed" "$ch/.config/systemd/user/hookline-watchdog.timer"
not_exists "systemd-live-cli-removed" "$cli"
contains "live-daemon-disable" "$(cat "$log")" "--user disable --now hookline-daemon.service"
contains "live-timer-disable" "$(cat "$log")" "--user disable --now hookline-watchdog.timer"
contains "live-daemon-reload-after-uninstall" "$(cat "$log")" "--user daemon-reload"

echo
echo "install-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
