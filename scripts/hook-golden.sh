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
PYBIN="/usr/bin/python3"   # asdf-proof — repo convention (never bare python3)
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

# Populate the sandboxed HOME for a case (config, settings, registry, flag).
setup_home() { # setup_home <home-dir> <setup>
  local h="$1" setup="$2"
  [ "$setup" = "noconfig" ] && return 0
  mkdir -p "$h/.config/hookline" "$h/.local/share/hookline" "$h/.claude"
  cat > "$h/.config/hookline/config" <<'CFG'
HOOKLINE_TOPIC=""
HOOKLINE_NTFY_SERVER="https://ntfy.sh"
HOOKLINE_GRACE_PERIOD=1
HOOKLINE_PHONE_TIMEOUT=2
HOOKLINE_EXTENDED_WAIT=0
CFG
  case "$setup" in
    allowlist)
      printf '%s\n' '{"permissions":{"allow":["Bash(safe*)"]}}' > "$h/.claude/settings.json"
      ;;
    providers:*)
      printf 'HOOKLINE_PROVIDERS="%s"\n' "${setup#providers:}" >> "$h/.config/hookline/config"
      ;;
    extended)
      # late-answer case: tiny phone timeout, fast extended-window cadence;
      # later lines win when the config is sourced
      printf 'HOOKLINE_EXTENDED_WAIT=120\nHOOKLINE_EXTENDED_INTERVAL=1\n' >> "$h/.config/hookline/config"
      ;;
    disabled)
      : > "$h/.config/hookline/disabled"
      ;;
    snoozed)
      # active mute window (now + 1h): the watcher must skip all phone traffic
      echo $(( $(date +%s) + 3600 )) > "$h/.local/share/hookline/snooze"
      ;;
    snoozed-expired)
      # stale window (60s in the past): notifies exactly like no snooze
      echo $(( $(date +%s) - 60 )) > "$h/.local/share/hookline/snooze"
      ;;
    header-off)
      # privacy: body metadata header line off, provider title tag stays
      printf 'HOOKLINE_ALERT_HEADER=0\n' >> "$h/.config/hookline/config"
      ;;
  esac
}

# run_case <name> <provider> <expected-stdout> <input-json> [setup: allowlist|disabled|providers:<list>|noconfig]
run_case() {
  local name="$1" provider="$2" expected="$3" input="$4" setup="${5:-}"
  local h out rc
  h=$(mktemp -d /tmp/hookline-golden.XXXXXX)

  setup_home "$h" "$setup"

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

# run_case_log <name> <provider> <pattern> <has|hasnt> <input-json> [setup] [expected-stdout]
# For providers whose contract is side effects (opencode writes decisions via
# the reply API, not stdout): asserts rc 0, pattern presence/absence in the
# sandboxed hook log, and stdout (empty by default, or containing
# expected-stdout when the provider emits a decision).
run_case_log() {
  local name="$1" provider="$2" pattern="$3" mode="$4" input="$5" setup="${6:-}" exp_out="${7:-}"
  local h out rc found=0
  h=$(mktemp -d /tmp/hookline-golden.XXXXXX)

  setup_home "$h" "$setup"

  out=$(printf '%s' "$input" | HOME="$h" TMUX='' bash "$HOOK" "$provider" 2>/dev/null)
  rc=$?
  # background baseline logs after an internal settle sleep (1s) — wait it out
  sleep 1.5
  grep -q -- "$pattern" "$h/.local/share/hookline/hookline.log" 2>/dev/null && found=1
  rm -rf "$h"

  local ok=1
  if [ -n "$exp_out" ]; then
    case "$out" in *"$exp_out"*) ;; *) ok=0 ;; esac
  else
    [ "$out" = "" ] || ok=0
  fi
  [ "$rc" -eq 0 ] || ok=0
  if [ "$mode" = "has" ]; then
    [ "$found" -eq 1 ] || ok=0
  else
    [ "$found" -eq 0 ] || ok=0
  fi

  if [ "$ok" -eq 1 ]; then
    echo "PASS $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL $name (rc=$rc, found=$found, mode=$mode)"
    echo "  stdout:   '$out'"
    FAIL=$((FAIL + 1))
  fi
}

[ -f "$HOOK" ] || { echo "hook not found: $HOOK"; exit 1; }

# ── Notify-payload capture: fake unix-socket daemon in the sandbox HOME ──
# Answers "status" with {"pid":...} (so daemon_alive passes), appends every
# other message to a capture file; asserts the notify message matches a jq
# filter. Covers the core→daemon JSON contract (no_actions / actions) that
# stdout/golden cannot see. No network: the empty HOOKLINE_TOPIC keeps the
# timeout notification from curling anywhere.
FAKE_DAEMON='
import json, os, socket, sys
path, cap = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.listen(5)
while True:
    c, _ = s.accept()
    data = b""
    while True:
        chunk = c.recv(4096)
        if not chunk:
            break
        data += chunk
    try:
        msg = json.loads(data.decode())
    except Exception:
        msg = {}
    if msg.get("type") == "status":
        c.sendall(json.dumps({"pid": os.getpid(), "sessions": 0, "pending": 0,
                              "heartbeat_age": 0, "sse_age": 0}).encode())
    else:
        with open(cap, "a") as f:
            f.write(json.dumps(msg) + "\n")
        c.sendall(b"ok")
    c.close()
'

# run_case_notify_payload <name> <provider> <input-json> <jq-filter> [setup] [expected-stdout]
# Runs the hook against a fake daemon and asserts the first captured notify
# message satisfies <jq-filter> (jq -e expression over the notify object).
# stdout must be empty unless expected-stdout is given (claude/codex emit a
# decision JSON on stdout; opencode writes nothing).
run_case_notify_payload() {
  local name="$1" provider="$2" input="$3" filter="$4" setup="${5:-}" exp_out="${6:-}"
  local h cap sock out rc notify="" pid ok=1
  h=$(mktemp -d /tmp/hookline-golden.XXXXXX)
  cap="$h/notify-cap.jsonl"
  sock="$h/.local/share/hookline/daemon.sock"

  setup_home "$h" "$setup"
  mkdir -p "$(dirname "$sock")"
  "$PYBIN" -c "$FAKE_DAEMON" "$sock" "$cap" 2>/dev/null &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -S "$sock" ] && break
    sleep 0.2
  done
  [ -S "$sock" ] || { echo "FAIL $name (fake daemon did not bind)"; FAIL=$((FAIL + 1)); kill "$pid" 2>/dev/null; rm -rf "$h"; return; }

  out=$(printf '%s' "$input" | HOME="$h" TMUX='' bash "$HOOK" "$provider" 2>/dev/null)
  rc=$?

  # notify leaves after sleep 1 + grace period (1s); phone poll then runs
  # PHONE_TIMEOUT=2s before the background process exits (lock file removed).
  # Wait for the background watcher to finish BEFORE reading the notify line —
  # the register message lands early and would otherwise end the wait too soon.
  local lock
  lock="$h/.local/share/hookline/session-$(printf '%s' "$input" | jq -r '.sessionID // .session_id // empty').lock"
  for _ in $(seq 1 40); do
    [ ! -f "$lock" ] && break
    sleep 0.25
  done
  # MSG_TYPE (default notify) picks which captured message the filter runs
  # against — register cases assert the context-keyword fields instead.
  notify=$(jq -c "select(.type==\"${MSG_TYPE:-notify}\")" "$cap" 2>/dev/null | head -1)
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  if [ "$filter" = "none" ]; then
    [ -z "$notify" ] || ok=0    # snoozed: no notify may reach the daemon
  else
    [ -n "$notify" ] || ok=0
  fi
  [ "$rc" -eq 0 ] || ok=0
  if [ -n "$exp_out" ]; then
    case "$out" in *"$exp_out"*) ;; *) ok=0 ;; esac
  else
    [ "$out" = "" ] || ok=0
  fi
  if [ "$filter" != "none" ] && [ -n "$notify" ]; then
    printf '%s' "$notify" | jq -e "$filter" >/dev/null 2>&1 || ok=0
  fi
  rm -rf "$h"

  if [ "$ok" -eq 1 ]; then
    echo "PASS $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL $name (rc=$rc)"
    echo "  notify: ${notify:-<none>}"
    echo "  filter: $filter"
    FAIL=$((FAIL + 1))
  fi
}

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

# ── opencode adapter cases: stdout contract is empty; assert the log instead ──
OPC_ASK='{"permission":"bash","patterns":["rm -rf /tmp/x"],"metadata":{"command":"rm -rf /tmp/x"},"id":"per_golden","sessionID":"golden-1"}'
OPC_SAFE='{"permission":"bash","patterns":["echo hi"],"metadata":{"command":"echo hi"},"id":"per_golden","sessionID":"golden-1"}'

run_case "opencode-no-config" opencode "config not found" '{}' noconfig

run_case_log "opencode-bash-ask" opencode "=== PreToolUse hook fired ===" has "$OPC_ASK"

run_case_log "opencode-safe-prefix" opencode "matches safe prefix" has "$OPC_SAFE"

run_case_log "opencode-disabled-flag" opencode "=== PreToolUse hook fired ===" hasnt "$OPC_ASK" disabled

if grep -q "HOOKLINE_PROVIDERS" "$HOOK"; then
  run_case_log "opencode-gate-excluded" opencode "=== PreToolUse hook fired ===" hasnt "$OPC_ASK" "providers:claude"

  run_case_log "opencode-gate-included" opencode "=== PreToolUse hook fired ===" has "$OPC_ASK" "providers:claude opencode"
else
  echo "SKIP opencode gate cases (entry has no HOOKLINE_PROVIDERS gate yet)"
fi

# ── opencode question-dialog cases: question.asked payloads ride the same flow;
#    stdout stays empty, the log carries the question decision + button count ──
OPC_Q3='{"id":"que_golden","sessionID":"golden-1","questions":[{"question":"Ship it?","header":"Ship","options":[{"label":"Alpha","description":"first"},{"label":"Beta","description":"second"},{"label":"Gamma","description":"third"}]}]}'
OPC_Q_MULTI='{"id":"que_golden","sessionID":"golden-1","questions":[{"question":"Pick several","header":"Pick","multiple":true,"options":[{"label":"Alpha","description":"first"},{"label":"Beta","description":"second"}]}]}'
OPC_Q_4OPT='{"id":"que_golden","sessionID":"golden-1","questions":[{"question":"Four is one too many","header":"Pick","options":[{"label":"One","description":"a"},{"label":"Two","description":"b"},{"label":"Three","description":"c"},{"label":"Four","description":"d"}]}]}'
OPC_Q_STACK='{"id":"que_golden","sessionID":"golden-1","questions":[{"question":"First?","header":"A","options":[{"label":"Yes","description":"y"},{"label":"No","description":"n"}]},{"question":"Second?","header":"B","options":[{"label":"Yes","description":"y"},{"label":"No","description":"n"}]}]}'

run_case_log "opencode-question-ask" opencode "OUTPUT: question active" has "$OPC_Q3"

run_case_log "opencode-question-buttons" opencode "question buttons: 3" has "$OPC_Q3"

run_case_log "opencode-question-multiselect-notify-only" opencode "question buttons: 0" has "$OPC_Q_MULTI"

run_case_log "opencode-question-fouropt-notify-only" opencode "question buttons: 0" has "$OPC_Q_4OPT"

run_case_log "opencode-question-stacked-notify-only" opencode "question buttons: 0" has "$OPC_Q_STACK"

# ── claude AskUserQuestion: same builder as opencode (parity) — defer stdout,
#    option buttons in the log, and the same notify payload contract ──
CLAUDE_Q3=$(jq -nc '{tool_name:"AskUserQuestion",
  tool_input:{questions:[{question:"Ship it?",header:"Ship",
    options:[{label:"Alpha",description:"first"},
             {label:"Beta",description:"second"},
             {label:"Gamma",description:"third"}]}]},
  cwd:"/tmp",session_id:"golden-2",transcript_path:"/dev/null"}')

run_case_log "claude-question-buttons" claude "question buttons: 3" has "$CLAUDE_Q3" "" "$DEFER"

run_case "claude-question-defers-three-opt" claude "$DEFER" "$CLAUDE_Q3"

# ── notify payload contract: core→daemon JSON carries the notify-only flag ──
# 4-opt question → no buttons at all (no default trio) but the label list +
# a reply hint travel for typed ("4"/"D") answering; 3-opt → option actions;
# permission → actions [] + no_actions false (daemon falls back to the trio).
run_case_notify_payload "opencode-q4-notify-no-actions" opencode "$OPC_Q_4OPT" \
  '.no_actions == true and (.actions | length) == 0
   and .options == ["One", "Two", "Three", "Four"]
   and (.message | contains("Reply 1-4 (or A-D) to answer"))'

run_case_notify_payload "opencode-q3-notify-option-actions" opencode "$OPC_Q3" \
  '(.no_actions | not) and (.actions | length) == 3 and .actions[0].payload == "answer|Alpha"
   and .options == ["Alpha", "Beta", "Gamma"]'

run_case_notify_payload "opencode-permission-notify-default-trio" opencode "$OPC_ASK" \
  '(.no_actions | not) and (.actions | length) == 0'

# ── snooze: an active mute window suppresses the phone notify entirely — the
#    decision still lands on stdout and the watcher exits cleanly (lock is
#    released). A stale window notifies exactly like no snooze.
run_case_notify_payload "claude-snoozed-no-notify" claude \
  "$(payload Bash '{"command":"rm -rf /tmp/x"}')" "none" snoozed "$ASK"

run_case_notify_payload "claude-snooze-expired-notifies" claude \
  "$(payload Bash '{"command":"rm -rf /tmp/x"}')" '.type == "notify"' \
  snoozed-expired "$ASK"

run_case_notify_payload "claude-question-notify-options" claude "$CLAUDE_Q3" \
  '.options == ["Alpha", "Beta", "Gamma"]
   and (.actions | length) == 3 and .actions[0].payload == "answer|Alpha"
   and (.message | contains("Reply 1-3 (or A-C) to answer"))' \
  "" "$DEFER"

# ── context keyword: the register payload carries the daemon's summary
#    inputs — provider (headless binary), transcript_path (file tail),
#    cwd (where the headless call runs) ──
MSG_TYPE=register
run_case_notify_payload "claude-register-context-fields" claude \
  "$(payload Bash '{"command":"rm -rf /tmp/x"}')" \
  '.provider == "claude" and (.transcript_path | type == "string")
   and (.cwd | type == "string") and .session_id != ""' \
  "" "$ASK"
run_case_notify_payload "opencode-register-context-fields" opencode "$OPC_ASK" \
  '.provider == "opencode" and .transcript_path == "" and .cwd != ""' "" ""
MSG_TYPE=notify

# ── notification metadata: provider rides the title, project/branch/dir the
#    body's first line; HOOKLINE_ALERT_HEADER=0 keeps the title, drops the
#    body line (fixture cwd is not a repo → header has no branch segment) ──
run_case_notify_payload "claude-notify-metadata" claude \
  "$(payload Bash '{"command":"rm -rf /tmp/x"}')" \
  '.title == "[claude · hookline-golden-proj] Bash"
   and (.message | startswith("hookline-golden-proj · /tmp/hookline-golden-proj\n\n"))
   and (.message | contains("$ rm -rf /tmp/x"))' \
  "" "$ASK"
run_case_notify_payload "opencode-notify-metadata" opencode "$OPC_ASK" \
  '.title == "[opencode · hookline] bash"
   and (.message | test("^hookline · "))
   and (.message | contains("rm -rf /tmp/x"))' "" ""
run_case_notify_payload "claude-metadata-header-off" claude \
  "$(payload Bash '{"command":"rm -rf /tmp/x"}')" \
  '.title == "[claude · hookline-golden-proj] Bash"
   and (.message | startswith("$ rm -rf /tmp/x"))' \
  header-off "$ASK"

# ── body budget: over 1500 chars the body compresses instead of losing tail
#    options — descriptions drop first, then option lines equal-share, so a
#    30-option question always arrives fully numbered and answerable; a short
#    question keeps its descriptions untouched.
OPC_Q30=$(jq -nc '{id:"que_golden",sessionID:"golden-1",
  questions:[{question:"Pick a number",header:"Big",
    options:[range(1;31) | {label:("Option \(.)"),
      description:("Long descriptive text for option \(.) that repeats across all thirty options and would blow the old fixed budget")}]}]}')

run_case_notify_payload "opencode-q30-compressed-keeps-all-options" opencode "$OPC_Q30" \
  '.no_actions == true and (.options | length) == 30
   and (.message | length) <= 1530
   and (.message | contains("1. Option 1"))
   and (.message | contains("30. Option 30"))
   and (.message | contains("Reply 1-30 to answer"))
   and ((.message | contains("would blow the old fixed budget")) | not)'

OPC_Q30_LONG=$(jq -nc '{id:"que_golden",sessionID:"golden-1",
  questions:[{question:"Pick a number",header:"Big",
    options:[range(1;31) | {label:("Option \(.) " + ([range(0;118) | "X"] | join(""))),
      description:"desc"}]}]}')

run_case_notify_payload "opencode-q30-long-labels-equal-share" opencode "$OPC_Q30_LONG" \
  '.no_actions == true and (.options | length) == 30
   and (.message | length) <= 1530
   and (.message | contains("1. Option 1 XXX"))
   and (.message | contains("30. Option 30 XXX"))
   and ((.message | contains(": desc")) | not)'

run_case_notify_payload "opencode-q3-keeps-descriptions" opencode "$OPC_Q3" \
  '.message | contains("1. Alpha: first") and contains("3. Gamma: third")'

# run_case_late_answer <name> <provider> <input-json> <setup>
# Extended-window contract: after PHONE_TIMEOUT the watcher must stay alive
# (extended wait) and still dispatch an answer written to the response file
# afterwards. Waits for the "extended wait" log line before writing, so the
# answer provably arrives after the phone timeout, not during normal polling.
run_case_late_answer() {
  local name="$1" provider="$2" input="$3" setup="$4"
  local h cap sock out rc pid notify="" rf="" ok=1 stage=0
  h=$(mktemp -d /tmp/hookline-golden.XXXXXX)
  cap="$h/notify-cap.jsonl"
  sock="$h/.local/share/hookline/daemon.sock"

  setup_home "$h" "$setup"
  mkdir -p "$(dirname "$sock")"
  "$PYBIN" -c "$FAKE_DAEMON" "$sock" "$cap" 2>/dev/null &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -S "$sock" ] && break
    sleep 0.2
  done
  [ -S "$sock" ] || { echo "FAIL $name (fake daemon did not bind)"; FAIL=$((FAIL + 1)); kill "$pid" 2>/dev/null; rm -rf "$h"; return; }

  out=$(printf '%s' "$input" | HOME="$h" TMUX='' bash "$HOOK" "$provider" 2>/dev/null)
  rc=$?

  # 1. notify reached the fake daemon
  for _ in $(seq 1 40); do
    notify=$(jq -c 'select(.type=="notify")' "$cap" 2>/dev/null | head -1)
    [ -n "$notify" ] && { stage=1; break; }
    sleep 0.25
  done
  # 2. phone timeout fired → watcher logged the extended window
  for _ in $(seq 1 40); do
    grep -q "phone timeout, extended wait" "$h/.local/share/hookline/hookline.log" 2>/dev/null \
      && { stage=2; break; }
    sleep 0.25
  done
  # 3. write the late answer the watcher must still pick up
  rf=$(printf '%s' "$notify" | jq -r '.response_file // empty')
  [ "$stage" -eq 2 ] && [ -n "$rf" ] && printf 'answer|Alpha' > "$rf"
  # 4. watcher dispatches and exits → lock gone
  local lock
  lock="$h/.local/share/hookline/session-$(printf '%s' "$input" | jq -r '.sessionID // empty').lock"
  for _ in $(seq 1 40); do
    [ ! -f "$lock" ] && { stage=3; break; }
    sleep 0.25
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  grep -q "phone timeout, extended wait" "$h/.local/share/hookline/hookline.log" 2>/dev/null || ok=0
  grep -q "daemon response: answer|Alpha" "$h/.local/share/hookline/hookline.log" 2>/dev/null || ok=0
  [ "$stage" -eq 3 ] || ok=0
  [ "$rc" -eq 0 ] || ok=0
  [ "$out" = "" ] || ok=0
  rm -rf "$h"

  if [ "$ok" -eq 1 ]; then
    echo "PASS $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL $name (rc=$rc, stage=$stage)"
    echo "  notify: ${notify:-<none>}"
    FAIL=$((FAIL + 1))
  fi
}

run_case_late_answer "opencode-late-answer-in-extended-window" opencode "$OPC_Q3" extended

# ── codex adapter cases: PermissionRequest contract — the initial decision is
#    an empty stdout (decline → codex's native approval menu owns the UI);
#    safe prefixes are the one foreground allow. Both logged, not just stdout ──
CX_ALLOW='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
CX_ASK='{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/x"},"cwd":"/tmp","session_id":"golden-cx","transcript_path":"/dev/null","permission_mode":"default"}'
CX_MCP='{"tool_name":"mcp__github__create_issue","tool_input":{"server":"github","tool":"create_issue"},"cwd":"/tmp","session_id":"golden-cx","transcript_path":"/dev/null"}'
CX_SAFE='{"tool_name":"Bash","tool_input":{"command":"echo hi"},"cwd":"/tmp","session_id":"golden-cx","transcript_path":"/dev/null"}'

run_case "codex-no-config" codex "config not found" '{}' noconfig

run_case_log "codex-bash-ask" codex "OUTPUT: decline (PermissionRequest" has "$CX_ASK"

run_case_log "codex-mcp-ask" codex "OUTPUT: decline (PermissionRequest" has "$CX_MCP"

run_case "codex-safe-prefix" codex "$CX_ALLOW" "$CX_SAFE"

run_case_log "codex-disabled-flag" codex "=== PreToolUse hook fired ===" hasnt "$CX_ASK" disabled

if grep -q "HOOKLINE_PROVIDERS" "$HOOK"; then
  run_case_log "codex-gate-excluded" codex "=== PreToolUse hook fired ===" hasnt "$CX_ASK" "providers:claude"

  run_case_log "codex-gate-included" codex "=== PreToolUse hook fired ===" has "$CX_ASK" "providers:claude codex"
else
  echo "SKIP codex gate cases (entry has no HOOKLINE_PROVIDERS gate yet)"
fi

# ── codex progress counter: raw rollout line count (no claude-style filtering
#    — the rollout only grows when the turn resolves) ──
CX_FIXTURE_DIR=$(mktemp -d /tmp/hookline-golden.XXXXXX)
CX_TRANSCRIPT="$CX_FIXTURE_DIR/rollout.jsonl"
printf '%s\n' '{"type":"event_msg"}' '{"type":"response_item"}' '{"type":"event_msg"}' > "$CX_TRANSCRIPT"
CX_PATCH=$(jq -nc --arg tp "$CX_TRANSCRIPT" \
  '{tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Update File: /tmp/x"},cwd:"/tmp",session_id:"golden-cx2",transcript_path:$tp}')

run_case_log "codex-progress-raw-rollout" codex \
  "baseline transcript lines: 3" has "$CX_PATCH" "" ""
rm -rf "$CX_FIXTURE_DIR"

# ── claude progress counter: transcript metadata lines are not local answers ──
FIXTURE_DIR=$(mktemp -d /tmp/hookline-golden.XXXXXX)
CLAUDE_TRANSCRIPT="$FIXTURE_DIR/transcript.jsonl"
printf '%s\n' \
  '{"type":"user","message":{"role":"user"}}' \
  '{"type":"ai-title","aiTitle":"x.txt file"}' \
  '{"type":"attachment","name":"foo"}' \
  '{"type":"assistant","message":{"role":"assistant"}}' \
  '{"type":"permission-mode","mode":"default"}' \
  > "$CLAUDE_TRANSCRIPT"
CLAUDE_WRITE=$(jq -nc --arg tp "$CLAUDE_TRANSCRIPT" \
  '{tool_name:"Write",tool_input:{file_path:"/tmp/x.txt",content:"x"},cwd:"/tmp",session_id:"golden-2",transcript_path:$tp}')

# 5 fixture lines, only 2 are user/assistant — raw wc would log 5 and the
# grace period would mistake claude's own metadata writes for an answer.
run_case_log "claude-progress-ignores-metadata" claude \
  "baseline transcript lines: 2" has "$CLAUDE_WRITE" "" '"permissionDecision":"ask"'
rm -rf "$FIXTURE_DIR"

# ── grok adapter cases: claude-shaped decisions against grok-native payloads ──
GRK_BASH='{"tool_name":"run_terminal_command","tool_input":{"command":"rm -rf /tmp/x"},"cwd":"/tmp","session_id":"golden-grk","transcript_path":"/dev/null"}'
GRK_SAFE='{"tool_name":"run_terminal_command","tool_input":{"command":"echo hi"},"cwd":"/tmp","session_id":"golden-grk","transcript_path":"/dev/null"}'
GRK_ALLOWLISTED='{"tool_name":"run_terminal_command","tool_input":{"command":"safe --flag"},"cwd":"/tmp","session_id":"golden-grk","transcript_path":"/dev/null"}'
GRK_WRITE='{"tool_name":"write","tool_input":{"file_path":"/tmp/x","content":"y"},"cwd":"/tmp","session_id":"golden-grk","transcript_path":"/dev/null"}'
GRK_Q3='{"tool_name":"ask_user_question","tool_input":{"questions":[{"question":"Ship it?","header":"Ship","options":[{"label":"Alpha","description":"first"},{"label":"Beta","description":"second"},{"label":"Gamma","description":"third"}]}]},"cwd":"/tmp","session_id":"golden-grk","transcript_path":"/dev/null"}'

run_case "grok-no-config" grok "config not found" '{}' noconfig

run_case "grok-bash-ask" grok "$ASK" "$GRK_BASH"

run_case "grok-safe-prefix" grok "$DEFER" "$GRK_SAFE"

run_case "grok-allowlisted" grok "$DEFER" "$GRK_ALLOWLISTED" allowlist

run_case "grok-write-ask" grok "$ASK" "$GRK_WRITE"

run_case "grok-question-defers" grok "$DEFER" "$GRK_Q3"

run_case_log "grok-disabled-flag" grok "=== PreToolUse hook fired ===" hasnt "$GRK_BASH" disabled "$DEFER"

if grep -q "HOOKLINE_PROVIDERS" "$HOOK"; then
  run_case "grok-gate-excluded" grok "" "$GRK_BASH" "providers:claude"

  run_case "grok-gate-included" grok "$ASK" "$GRK_BASH" "providers:claude grok"
else
  echo "SKIP grok gate cases (entry has no HOOKLINE_PROVIDERS gate yet)"
fi

# ── grok notify payload: native tool names in the message, question parity ──
run_case_notify_payload "grok-permission-notify-default-trio" grok "$GRK_BASH" \
  '(.no_actions | not) and (.actions | length) == 0
   and (.message | contains("$ rm -rf /tmp/x"))' \
  "" "$ASK"

run_case_notify_payload "grok-write-notify-path" grok "$GRK_WRITE" \
  '.message | contains("write: /tmp/x")' \
  "" "$ASK"

run_case_notify_payload "grok-question-notify-options" grok "$GRK_Q3" \
  '.options == ["Alpha", "Beta", "Gamma"]
   and (.actions | length) == 3 and .actions[0].payload == "answer|Alpha"
   and (.message | contains("Reply 1-3 (or A-C) to answer"))' \
  "" "$DEFER"

# ── grok progress counter: raw updates.jsonl line count (only grows when the
#    turn resolves — permission cards sit idle) ──
GRK_FIXTURE_DIR=$(mktemp -d /tmp/hookline-golden.XXXXXX)
GRK_TRANSCRIPT="$GRK_FIXTURE_DIR/updates.jsonl"
printf '%s\n' '{"type":"tool"}' '{"type":"tool"}' '{"type":"tool"}' > "$GRK_TRANSCRIPT"
GRK_WRITE_FIX=$(jq -nc --arg tp "$GRK_TRANSCRIPT" \
  '{tool_name:"write",tool_input:{file_path:"/tmp/x",content:"y"},cwd:"/tmp",session_id:"golden-grk2",transcript_path:$tp}')

run_case_log "grok-progress-raw-transcript" grok \
  "baseline transcript lines: 3" has "$GRK_WRITE_FIX" "" "$ASK"
rm -rf "$GRK_FIXTURE_DIR"

# ── grok allow-row parser: the card's allow-once digit, per prompt class ──
# Row order varies (bash/edit/ask cards) and Enter would hit the
# always-approve preselect, so injection reads the digit off the screenshot;
# no matching row must yield no digit (injector logs and does nothing).
grok_parse_case() { # grok_parse_case <name> <expected> <fixture-line>...
  local name="$1" expect="$2" got
  shift 2
  got=$(printf '%s\n' "$@" \
    | bash -c '. "$1" >/dev/null 2>&1; grok_allow_digit' _ "$REPO/hooks/adapters/grok.sh")
  if [ "$got" = "$expect" ]; then
    echo "PASS $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL $name (got '$got', want '$expect')"
    FAIL=$((FAIL + 1))
  fi
}

grok_parse_case "grok-parse-bash-card" "3" \
  '  1 (●) Yes, and don'"'"'t ask again for anything (always-approve mode)' \
  '  2 (○) Always allow: touch /tmp/x' \
  '  3 (○) Yes, proceed' \
  '  4 (○) No, reject (type to add feedback)' \
  '  5 (○) Never allow: touch /tmp/x'

grok_parse_case "grok-parse-edit-card" "3" \
  '  1 (●) Yes, and don'"'"'t ask again for anything (always-approve mode)' \
  '  2 (○) Yes, allow all edits during this session' \
  '  3 (○) Yes' \
  '  4 (○) No, reject (type to add feedback)'

grok_parse_case "grok-parse-ask-card" "3" \
  '  1 (●) Yes, and don'"'"'t ask again for anything (always-approve mode)' \
  '  2 (○) always allow' \
  '  3 (○) allow once' \
  '  4 (○) No, reject (type to add feedback)'

grok_parse_case "grok-parse-remember-off" "2" \
  '  1 (●) Yes, don'"'"'t ask again for anything (always-approve mode)' \
  '  2 (○) Yes, proceed' \
  '  3 (○) No, reject (type to add feedback)'

# real pane capture: box-border prefix on every row, scrollbar glyph after
grok_parse_case "grok-parse-boxed-card" "3" \
  '  ┃  1 (●) Yes, and don'"'"'t ask again for anything (always-approve mode)' \
  '  ┃  2 (○) Yes, allow all edits during this session' \
  '  ┃  3 (○) Yes                              █' \
  '  ┃  4 (○) No, reject (type to add feedback)'

grok_parse_case "grok-parse-no-row" "" \
  '  1 (○) something else' \
  '  prompt waiting'

echo
echo "golden: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
