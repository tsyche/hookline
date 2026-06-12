#!/bin/bash
# hookline — Claude Code PreToolUse hook → ntfy.sh remote approval
# Shows terminal prompt immediately; sends phone notification after grace period.
# Daemon mode: SSE-based instant response; hook process handles keystroke injection
#              (runs in terminal's process tree, no extra accessibility permissions).
# Fallback mode: inline polling when daemon is not running.

CONFIG_FILE="${HOME}/.config/hookline/config"
LOG_FILE="${HOME}/.local/share/hookline/hookline.log"
DAEMON_SOCK="${HOME}/.local/share/hookline/daemon.sock"
SETTINGS_GLOBAL="${HOME}/.claude/settings.json"
SETTINGS_LOCAL="${CWD:+$CWD/.claude/settings.local.json}"
SETTINGS_LOCAL="${SETTINGS_LOCAL:-${HOME}/.claude/settings.local.json}"
DISABLED_FLAG="${HOME}/.config/hookline/disabled"

# Resolve an asdf-proof Python. A bare `python3` resolves to an asdf shim in
# any directory with a .tool-versions pointing at an uninstalled version — which
# breaks the daemon handoff silently. Prefer the absolute system interpreter.
PYBIN="/usr/bin/python3"
[ -x "$PYBIN" ] || PYBIN="$(command -v python3)"

log() {
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${REQ_ID:-init}" "$*" >> "$LOG_FILE"
}

# Send a JSON message to the daemon socket; returns 0 on success.
daemon_send() {
  "$PYBIN" -c "
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(3)
try:
    s.connect('${DAEMON_SOCK}')
    s.sendall(sys.stdin.buffer.read())
    s.shutdown(socket.SHUT_WR)
    s.recv(64)
    sys.exit(0)
except:
    sys.exit(1)
finally:
    s.close()
" <<< "$1" 2>/dev/null
}

# True only if the daemon is actually responsive — not merely that a (possibly
# stale) socket file exists. Guards against a hung daemon swallowing handoffs.
daemon_alive() {
  [ -S "$DAEMON_SOCK" ] || return 1
  local resp
  resp=$("$PYBIN" -c "
import socket, json, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(3)
try:
    s.connect('${DAEMON_SOCK}')
    s.sendall(json.dumps({'type':'status'}).encode())
    s.shutdown(socket.SHUT_WR)
    sys.stdout.write(s.recv(4096).decode())
    sys.exit(0)
except:
    sys.exit(1)
finally:
    s.close()
" 2>/dev/null)
  [[ "$resp" == *'"pid"'* ]]
}

source "$CONFIG_FILE" 2>/dev/null || { echo "config not found"; exit 0; }

if [ -f "$DISABLED_FLAG" ]; then
  jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"defer"}}'
  exit 0
fi

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "Unknown"')
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input // {} | tostring' | head -c 300)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
PROJECT=$(basename "$CWD" 2>/dev/null || echo "unknown")
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

# Notification title label. Inside tmux, show "session / project" so the title
# names both the terminal to switch to AND the codebase — Claude's reported CWD
# can be stale (e.g. --resume restores an old dir) and collide with an unrelated
# tmux session name. Outside tmux, just the project basename.
TMUX_SESSION=""
[ -n "${TMUX:-}" ] && TMUX_SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null)
if [ -n "$TMUX_SESSION" ] && [ "$TMUX_SESSION" != "$PROJECT" ]; then
  SESSION_LABEL="$TMUX_SESSION / $PROJECT"
else
  SESSION_LABEL="$PROJECT"
fi

REQ_ID="$(date +%s)-$$"
PARENT_TTY=$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ')

log "=== PreToolUse hook fired ==="
log "cwd: $CWD | project: $PROJECT | tmux_session: ${TMUX_SESSION:-none} | label: $SESSION_LABEL"
log "tool: $TOOL_NAME | parent_tty: $PARENT_TTY"
log "transcript_path: $TRANSCRIPT_PATH"
log "session_id: $SESSION_ID"

# 1. Check allowlist — skip notification entirely if matched
SAFE_PREFIXES=("echo " "stat " "ls " "pwd " "pwd" "cat " "grep " "find " "date " "whoami " "hostname " "uname " "which " "type " "file " "head " "tail " "wc " "sort " "uniq " "cut " "tr ")

if [ "$TOOL_NAME" = "Bash" ]; then
  cmd=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
  [ -z "$cmd" ] && cmd="$TOOL_INPUT"
  log "extracted bash command: $cmd"

  for prefix in "${SAFE_PREFIXES[@]}"; do
    if [[ "$cmd" == "$prefix"* ]]; then
      log "matches safe prefix: $prefix → defer silently"
      jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"defer"}}'
      exit 0
    fi
  done

  for _settings_file in "$SETTINGS_GLOBAL" "$SETTINGS_LOCAL"; do
    [ -f "$_settings_file" ] || continue
    patterns=$(jq -r '.permissions.allow[] | select(startswith("Bash(")) | sub("Bash\\("; "") | sub("\\)$"; "")' "$_settings_file" 2>/dev/null)
    while IFS= read -r pattern; do
      [ -z "$pattern" ] && continue
      if [[ "$pattern" == *\* ]]; then
        prefix="${pattern%\*}"
        if [[ "$cmd" == "$prefix"* ]]; then
          log "matches allowlist pattern in $_settings_file: Bash($pattern) → defer silently"
          jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"defer"}}'
          exit 0
        fi
      else
        if [ "$cmd" = "$pattern" ]; then
          log "matches allowlist pattern (exact) in $_settings_file: Bash($pattern) → defer silently"
          jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"defer"}}'
          exit 0
        fi
      fi
    done <<< "$patterns"
  done
fi

# 2. Output decision. AskUserQuestion is not a permission gate — it always shows
#    its own multi-option picker — so defer rather than forcing a yes/no "ask".
#    The background watcher still notifies and (on phone response) injects into
#    the displayed picker. Everything else gets "ask" to surface the prompt.
if [ "$TOOL_NAME" = "AskUserQuestion" ]; then
  log "OUTPUT: defer (AskUserQuestion — multi-option picker)"
  jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"defer"}}'
else
  log "OUTPUT: ask"
  jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask"}}'
fi

# 3. Build notification message
if [ "$TOOL_NAME" = "Bash" ]; then
  _cmd=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
  NOTIFY_MSG="$ ${_cmd:0:280}"
elif [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; then
  _path=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
  NOTIFY_MSG="${TOOL_NAME}: $_path"
elif [ "$TOOL_NAME" = "NotebookEdit" ]; then
  _path=$(echo "$INPUT" | jq -r '.tool_input.path // ""' 2>/dev/null)
  NOTIFY_MSG="NotebookEdit: $_path"
elif [ "$TOOL_NAME" = "AskUserQuestion" ]; then
  # Multi-option question — warn that Allow picks option 1 and Deny dismisses.
  _q=$(echo "$INPUT" | jq -r '.tool_input.questions[0].question // .tool_input.questions[0].header // "multi-option question"' 2>/dev/null)
  NOTIFY_MSG="⚠️ ${_q:0:230} — Allow picks option 1, Deny dismisses"
else
  NOTIFY_MSG="${TOOL_INPUT:0:300}"
fi

GRACE_PERIOD="${HOOKLINE_GRACE_PERIOD:-20}"
PHONE_TIMEOUT="${HOOKLINE_PHONE_TIMEOUT:-900}"
MAX_RETRIES="${HOOKLINE_MAX_RETRIES:-3}"

# 4. Register session with daemon (captures TTY + terminal info for routing)
if daemon_alive; then
  TMUX_PANE_ID="${TMUX_PANE:-$(tmux display-message -p '#{pane_id}' 2>/dev/null)}"
  daemon_send "$(jq -nc \
    --arg type "register" \
    --arg session_id "$SESSION_ID" \
    --arg tty "$PARENT_TTY" \
    --arg term_program "${TERM_PROGRAM:-}" \
    --arg tmux_pane "${TMUX_PANE_ID:-}" \
    '{type:$type,session_id:$session_id,tty:$tty,term_program:$term_program,tmux_pane:$tmux_pane}')"
  log "registered session with daemon"
fi

# 5. Per-session lock: kill any existing grace-period process for this session
LOCK_FILE="${HOME}/.local/share/hookline/session-${SESSION_ID}.lock"
if [ -f "$LOCK_FILE" ]; then
  old_pid=$(cat "$LOCK_FILE" 2>/dev/null)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    log "killing previous session background process $old_pid"
    kill "$old_pid" 2>/dev/null
  fi
fi

# 6. Background process: grace period watcher + response handler
(
  trap '[[ "$(cat "$LOCK_FILE" 2>/dev/null)" == "$BASHPID" ]] && rm -f "$LOCK_FILE"' EXIT

  sleep 1
  INITIAL_LINES=$(wc -l < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ' || echo "0")
  log "background: baseline transcript lines: $INITIAL_LINES, starting ${GRACE_PERIOD}s grace period..."
  sleep "$GRACE_PERIOD"

  CURRENT_LINES=$(wc -l < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ' || echo "0")
  if [ "$CURRENT_LINES" -gt "$INITIAL_LINES" ]; then
    log "background: transcript grew ($INITIAL_LINES → $CURRENT_LINES lines), user answered locally, exiting"
    exit 0
  fi
  log "background: no new transcript lines, user likely away"

  inject_keystroke() {
    local action="$1"   # "allow" or "deny"
    local label="$2"
    # allow → type "1" + Enter (option 1 is always "Yes")
    # deny  → Escape (key code 53), which cancels the prompt regardless of how
    #         many options the menu has — "3" breaks on 2-option menus.
    local proc=""
    case "${TERM_PROGRAM:-}" in
      iTerm.app)      proc="iTerm2" ;;
      Apple_Terminal) proc="Terminal" ;;
      WezTerm)        proc="WezTerm" ;;
    esac
    log "background: injecting '$action' ($label) via ${TERM_PROGRAM:-frontmost}"
    if [ "$action" = "deny" ]; then
      if [ -n "$proc" ]; then
        osascript -e "tell application \"System Events\" to tell process \"$proc\" to key code 53" 2>/dev/null
      else
        osascript -e "tell application \"System Events\" to key code 53" 2>/dev/null
      fi
    else
      if [ -n "$proc" ]; then
        osascript \
          -e "tell application \"System Events\" to tell process \"$proc\" to keystroke \"1\"" \
          -e "tell application \"System Events\" to tell process \"$proc\" to key code 36" \
          2>/dev/null
      else
        osascript \
          -e "tell application \"System Events\" to keystroke \"1\"" \
          -e "tell application \"System Events\" to key code 36" \
          2>/dev/null
      fi
    fi
  }

  send_timeout_notification() {
    local _topic="${HOOKLINE_TOPIC:-}"
    local _server="${HOOKLINE_NTFY_SERVER:-https://ntfy.sh}"
    [ -z "$_topic" ] && return
    local _auth=()
    [ -n "$HOOKLINE_NTFY_USERNAME" ] && _auth=(-u "${HOOKLINE_NTFY_USERNAME}:${HOOKLINE_NTFY_PASSWORD}")
    curl -s "${_auth[@]}" -H "Content-Type: application/json" \
      -d "$(jq -nc \
        --arg topic "$_topic" \
        --arg title "[$SESSION_LABEL] Prompt expired" \
        --arg message "No response after ${PHONE_TIMEOUT}s — Claude is waiting at the terminal" \
        '{topic:$topic,title:$title,message:$message,priority:2,tags:["hourglass_done"]}')" \
      "${_server}/" &>/dev/null
  }

  # — Daemon path —
  if daemon_alive; then
    log "background: daemon available, handing off notification"
    RESPONSE_FILE="/tmp/hookline-resp-${REQ_ID}"
    trap 'rm -f "$RESPONSE_FILE"; [[ "$(cat "$LOCK_FILE" 2>/dev/null)" == "$BASHPID" ]] && rm -f "$LOCK_FILE"' EXIT

    retries=0
    current_req_id="$REQ_ID"
    while true; do
      rm -f "$RESPONSE_FILE"
      daemon_send "$(jq -nc \
        --arg type "notify" \
        --arg session_id "$SESSION_ID" \
        --arg req_id "$current_req_id" \
        --arg title "[$SESSION_LABEL] $TOOL_NAME" \
        --arg message "$NOTIFY_MSG" \
        --arg response_file "$RESPONSE_FILE" \
        --argjson max_retries "$MAX_RETRIES" \
        '{type:$type,session_id:$session_id,req_id:$req_id,title:$title,message:$message,response_file:$response_file,max_retries:$max_retries}')"

      # Poll for daemon's response, checking transcript in parallel
      decision=""
      elapsed=0
      while [ "$elapsed" -lt "$PHONE_TIMEOUT" ]; do
        sleep 1
        elapsed=$((elapsed + 1))

        # Cancel if user answered at terminal
        cur=$(wc -l < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ' || echo "0")
        if [ "$cur" -gt "$INITIAL_LINES" ]; then
          log "background: transcript grew during polling, user answered at terminal"
          daemon_send "$(jq -nc --arg type "cancel" --arg req_id "$current_req_id" '{type:$type,req_id:$req_id}')"
          exit 0
        fi

        if [ -f "$RESPONSE_FILE" ]; then
          decision=$(cat "$RESPONSE_FILE")
          rm -f "$RESPONSE_FILE"
          break
        fi
      done

      if [ -z "$decision" ]; then
        log "background: timed out, giving up"
        send_timeout_notification
        exit 0
      fi
      log "background: daemon response: $decision"

      if [ "$decision" = "allow" ]; then
        inject_keystroke "allow" "Allow"
        exit 0
      elif [ "$decision" = "deny" ]; then
        inject_keystroke "deny" "Deny"
        exit 0
      elif [ "$decision" = "retry" ]; then
        retries=$((retries + 1))
        if [ "$retries" -ge "$MAX_RETRIES" ]; then
          log "background: max retries ($MAX_RETRIES) reached, giving up"
          exit 0
        fi
        current_req_id="${REQ_ID}-r${retries}"
        log "background: retry $retries/$MAX_RETRIES → $current_req_id"
      else
        exit 0
      fi
    done
  fi

  # — Legacy fallback (no daemon): inline polling —
  log "background: daemon not available, using legacy polling"
  TOPIC="${HOOKLINE_TOPIC:?hookline: HOOKLINE_TOPIC not set in config}"
  NTFY_SERVER="${HOOKLINE_NTFY_SERVER:-https://ntfy.sh}"
  RESPONSE_TOPIC="${TOPIC}-response"

  send_notification() {
    local req_id="$1"
    THROTTLE_FILE="${HOME}/.local/share/hookline/ntfy-throttle"
    THROTTLE_INTERVAL="${HOOKLINE_NTFY_MIN_INTERVAL:-5}"
    last_req=$(cat "$THROTTLE_FILE" 2>/dev/null || echo 0)
    elapsed=$(( $(date +%s) - last_req ))
    if [ "$elapsed" -lt "$THROTTLE_INTERVAL" ]; then
      sleep $(( THROTTLE_INTERVAL - elapsed ))
    fi
    date +%s > "$THROTTLE_FILE"

    log "background: sending notification..."
    AUTH_ARGS=()
    [ -n "$HOOKLINE_NTFY_USERNAME" ] && AUTH_ARGS=(-u "${HOOKLINE_NTFY_USERNAME}:${HOOKLINE_NTFY_PASSWORD}")
    curl -s "${AUTH_ARGS[@]}" -H "Content-Type: application/json" \
      -d "$(jq -nc \
        --arg topic "$TOPIC" \
        --arg title "[$SESSION_LABEL] $TOOL_NAME" \
        --arg message "$NOTIFY_MSG" \
        --arg url "${NTFY_SERVER}/${RESPONSE_TOPIC}" \
        '{topic:$topic,title:$title,message:$message,priority:4,tags:["lock"],
          actions:[
            {action:"http",label:"Allow",url:$url,method:"POST",body:"allow|'"$req_id"'"},
            {action:"http",label:"Deny", url:$url,method:"POST",body:"deny|'"$req_id"'"},
            {action:"http",label:"Retry",url:$url,method:"POST",body:"retry|'"$req_id"'"}
          ]}')" "${NTFY_SERVER}/" > /tmp/ntfy-resp-${req_id}.json 2>&1
    response_id=$(jq -r '.id // "NO_ID"' /tmp/ntfy-resp-${req_id}.json 2>/dev/null)
    log "notification sent, response id: $response_id"

    DECISION=""
    local elapsed=0
    local since_id="$response_id"
    while [ "$elapsed" -lt "$PHONE_TIMEOUT" ]; do
      sleep 8
      elapsed=$((elapsed + 8))
      msgs=$(curl -s --max-time 5 "${AUTH_ARGS[@]}" \
        "${NTFY_SERVER}/${RESPONSE_TOPIC}/json?poll=1&since=${since_id}" 2>/dev/null)
      while IFS= read -r msg; do
        [ -z "$msg" ] && continue
        msg_id=$(echo "$msg" | jq -r '.id // empty' 2>/dev/null)
        MSG=$(echo "$msg" | jq -r '.message // empty' 2>/dev/null)
        [ -n "$msg_id" ] && since_id="$msg_id"
        if [[ "$MSG" == *"|${req_id}" ]]; then
          DECISION="${MSG%%|*}"
          log "background: phone response: $DECISION"
          return 0
        fi
      done <<< "$msgs"
    done
    return 1
  }

  retries=0
  current_req="${REQ_ID}"
  while true; do
    if send_notification "$current_req"; then
      if [ "$DECISION" = "allow" ]; then
        inject_keystroke "allow" "Allow"; break
      elif [ "$DECISION" = "deny" ]; then
        inject_keystroke "deny" "Deny"; break
      elif [ "$DECISION" = "retry" ]; then
        retries=$((retries + 1))
        if [ "$retries" -ge "$MAX_RETRIES" ]; then
          log "background: max retries ($MAX_RETRIES) reached, giving up"
          break
        fi
        current_req="${REQ_ID}-r${retries}"
        log "background: retry $retries/$MAX_RETRIES"
      fi
    else
      log "background: notification timed out, giving up"
      send_timeout_notification
      break
    fi
  done
) &>/dev/null &
echo "$!" > "$LOCK_FILE"

log "=== hook complete ==="
exit 0
