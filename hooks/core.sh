#!/bin/bash
# shellcheck disable=SC2034,SC2153  # contract vars assigned by entry/adapter (sources not followed)
# hookline core — provider-neutral flow. Sourced by hooks/hookline.sh after
# config + registry gate; the selected adapter (hooks/adapters/*.sh) must
# already be sourced when core_main runs. Adapter interface:
#
#   ADAPTER_MATCHER              tool matcher string for registration
#   HOOKLINE_WAITING_AGENT       name used in the "prompt expired" notification
#   adapter_normalize            $INPUT (raw stdin JSON) → TOOL_NAME, TOOL_INPUT,
#                                CWD, TRANSCRIPT_PATH, SESSION_ID
#   adapter_command              echo the Bash command ("" = not a Bash tool)
#   adapter_allowlist <cmd>      return 0 = allowlisted (logs + emits defer)
#   adapter_emit_decision <d>    emit provider decision JSON (ask|defer)
#   adapter_emit_initial_decision  emit the default decision for this payload
#   adapter_build_message        set NOTIFY_MSG for the notification body
#   adapter_progress_lines       echo monotonic local-user-progress counter
#                                (claude: transcript line count)
#   adapter_inject <action> <label>  inject keystroke for allow|deny

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

core_main() {
  if [ -f "$DISABLED_FLAG" ]; then
    adapter_emit_decision defer
    exit 0
  fi

  INPUT=$(cat)
  adapter_normalize
  PROJECT=$(basename "$CWD" 2>/dev/null || echo "unknown")

  # Notification title label. Inside tmux, show "session / project" so the title
  # names both the terminal to switch to AND the codebase — the reported CWD
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

  cmd=$(adapter_command)
  if [ -n "$cmd" ]; then
    log "extracted bash command: $cmd"

    for prefix in "${SAFE_PREFIXES[@]}"; do
      if [[ "$cmd" == "$prefix"* ]]; then
        log "matches safe prefix: $prefix → defer silently"
        adapter_emit_decision defer
        exit 0
      fi
    done

    if adapter_allowlist "$cmd"; then
      exit 0
    fi
  fi

  # 2. Output decision. The adapter picks the default (claude: AskUserQuestion
  #    is not a permission gate — it always shows its own multi-option picker —
  #    so defer rather than forcing a yes/no "ask"; everything else gets "ask"
  #    to surface the prompt). The background watcher still notifies and (on
  #    phone response) injects into the displayed picker.
  adapter_emit_initial_decision

  # 3. Build notification message
  adapter_build_message

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
    INITIAL_LINES=$(adapter_progress_lines)
    log "background: baseline transcript lines: $INITIAL_LINES, starting ${GRACE_PERIOD}s grace period..."
    sleep "$GRACE_PERIOD"

    CURRENT_LINES=$(adapter_progress_lines)
    if [ "$CURRENT_LINES" -gt "$INITIAL_LINES" ]; then
      log "background: transcript grew ($INITIAL_LINES → $CURRENT_LINES lines), user answered locally, exiting"
      exit 0
    fi
    log "background: no new transcript lines, user likely away"

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
          --arg message "No response after ${PHONE_TIMEOUT}s — ${HOOKLINE_WAITING_AGENT} is waiting at the terminal" \
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
          cur=$(adapter_progress_lines)
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
          adapter_inject "allow" "Allow"
          exit 0
        elif [ "$decision" = "deny" ]; then
          adapter_inject "deny" "Deny"
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
      ntfy_resp=$(curl -s "${AUTH_ARGS[@]}" -H "Content-Type: application/json" \
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
            ]}')" "${NTFY_SERVER}/" 2>&1)
      response_id=$(jq -r '.id // "NO_ID"' <<<"$ntfy_resp" 2>/dev/null)
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
          adapter_inject "allow" "Allow"; break
        elif [ "$DECISION" = "deny" ]; then
          adapter_inject "deny" "Deny"; break
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
}
