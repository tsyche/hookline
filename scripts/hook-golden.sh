#!/bin/bash
# Golden stdout tests for the hook entry point.
#
# Runs hooks/hookline.sh against fixture payloads inside an isolated fake HOME
# (config, settings, logs all sandboxed — no network, no daemon) and compares
# stdout byte-for-byte. The hook's observable contract is its stdout: the
# provider decision JSON (or early-exit text). Background watcher side effects
# are sandboxed away by an empty HOOKLINE_TOPIC (the legacy notify path aborts
# on `${HOOKLINE_TOPIC:?...}` before any network call).
#
# Usage: bash scripts/hook-golden.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/hooks/hookline.sh"
PASS=0
FAIL=0

ASK='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask"}}'
DEFER='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"defer"}}'
BASE_JSON='{"cwd":"/tmp/hookline-golden-proj","transcript_path":"/dev/null","session_id":"golden-1","tool_name":"@TOOL@","tool_input":@INPUT@}'

payload() { # payload <tool_name> <tool_input-json>
  local p="$BASE_JSON"
  p="${p//@TOOL@/$1}"
  p="${p//@INPUT@/$2}"
  printf '%s' "$p"
}

# run_case <name> <provider> <expected-stdout> <input-json> [setup: allowlist|disabled|providers:<list>|noconfig]
run_case() {
  local name="$1" provider="$2" expected="$3" input="$4" setup="${5:-}"
  local h out rc
  h=$(mktemp -d /tmp/hookline-golden.XXXXXX)

  if [ "$setup" != "noconfig" ]; then
    mkdir -p "$h/.config/hookline" "$h/.local/share/hookline" "$h/.claude"
    cat > "$h/.config/hookline/config" <<'CFG'
HOOKLINE_TOPIC=""
HOOKLINE_NTFY_SERVER="https://ntfy.sh"
HOOKLINE_GRACE_PERIOD=1
HOOKLINE_PHONE_TIMEOUT=2
CFG
    case "$setup" in
      allowlist)
        printf '%s\n' '{"permissions":{"allow":["Bash(safe*)"]}}' > "$h/.claude/settings.json"
        ;;
      providers:*)
        printf 'HOOKLINE_PROVIDERS="%s"\n' "${setup#providers:}" >> "$h/.config/hookline/config"
        ;;
      disabled)
        : > "$h/.config/hookline/disabled"
        ;;
    esac
  fi

  out=$(printf '%s' "$input" | HOME="$h" TMUX='' bash "$HOOK" "$provider" 2>/dev/null)
  rc=$?
  rm -rf "$h"

  if [ "$out" = "$expected" ] && [ "$rc" -eq 0 ]; then
    echo "PASS $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL $name (rc=$rc)"
    echo "  expected: $expected"
    echo "  actual:   $out"
    FAIL=$((FAIL + 1))
  fi
}

[ -f "$HOOK" ] || { echo "hook not found: $HOOK"; exit 1; }

# ── Parity cases: must hold before and after the core/adapter split ──
run_case "no-config" claude "config not found" '{}' noconfig

run_case "bash-ask" claude "$ASK" \
  "$(payload Bash '{"command":"rm -rf /tmp/x"}')"

run_case "bash-safe-prefix" claude "$DEFER" \
  "$(payload Bash '{"command":"echo hi"}')"

run_case "bash-allowlisted" claude "$DEFER" \
  "$(payload Bash '{"command":"safe --flag"}')" allowlist

run_case "askuserquestion-defers" claude "$DEFER" \
  "$(payload AskUserQuestion '{"questions":[{"question":"pick?"}]}')"

run_case "write-ask" claude "$ASK" \
  "$(payload Write '{"file_path":"/tmp/x"}')"

run_case "disabled-flag" claude "$DEFER" \
  "$(payload Bash '{"command":"rm -rf /tmp/x"}')" disabled

# ── Registry-gate cases: only meaningful once the entry gained HOOKLINE_PROVIDERS
#    (skipped against the pre-refactor monolith, which has no gate) ──
if grep -q "HOOKLINE_PROVIDERS" "$HOOK"; then
  run_case "gate-provider-excluded" blackbox "" \
    "$(payload Bash '{"command":"rm -rf /tmp/x"}')" "providers:claude"

  run_case "gate-provider-included" claude "$ASK" \
    "$(payload Bash '{"command":"rm -rf /tmp/x"}')" "providers:claude"

  run_case "gate-unset-all-enabled" blackbox "$ASK" \
    "$(payload Bash '{"command":"rm -rf /tmp/x"}')"
else
  echo "SKIP gate cases (entry has no HOOKLINE_PROVIDERS gate yet)"
fi

echo
echo "golden: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
