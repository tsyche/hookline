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

# ── snooze ─────────────────────────────────────────────────────────────────────
# Phone-notification mute window (set by `hookline snooze N` or a typed
# "snooze" reply from the ntfy app). The file holds a future unix epoch.
# While active, no ntfy push goes out — the terminal prompt stays and the
# watcher keeps checking the transcript for a local answer. Shared check with
# the daemon (which guards its own sends for retries/feedback).
SNOOZE_FILE="${HOME}/.local/share/hookline/snooze"

snooze_active() {
  local exp
  exp=$(cat "$SNOOZE_FILE" 2>/dev/null) || return 1
  case "$exp" in ''|*[!0-9]*) return 1 ;; esac
  [ "$exp" -gt "$(date +%s)" ]
}

# Equal-share fit: shrink a rendered question body to <= budget chars without
# dropping any numbered option line. Non-option lines (headers, blanks) are
# capped at a third of the budget first; every option line then shares the
# remainder equally, truncated with "..." when too long. Prints nothing when
# even the prefixes cannot fit — the caller falls back to a hard cut.
fit_question_body() {
  awk -v B="$1" '
    { L[++n] = $0; if ($0 ~ /^[0-9]+\. /) opts[++nopt] = n; else other[++nother] = n }
    END {
      if (nopt == 0) exit 1
      olen = 0
      for (i = 1; i <= nother; i++) olen += length(L[other[i]]) + 1
      if (olen > int(B / 3)) {
        share = nother > 0 ? int((B / 3) / nother) : 0
        if (share < 10) exit 1
        for (i = 1; i <= nother; i++) {
          k = other[i]
          if (length(L[k]) > share - 1) L[k] = substr(L[k], 1, share - 4) "..."
        }
        olen = 0
        for (i = 1; i <= nother; i++) olen += length(L[other[i]]) + 1
      }
      per = int((B - olen) / nopt)
      if (per < 10) exit 1
      for (i = 1; i <= nopt; i++) {
        k = opts[i]
        if (length(L[k]) > per - 1) L[k] = substr(L[k], 1, per - 4) "..."
      }
      out = L[1]
      for (i = 2; i <= n; i++) out = out "\n" L[i]
      print out
    }'
}

# Question dialog → human-readable body (every question, numbered options with
# descriptions) + optional ntfy action buttons. Provider-neutral: reads
# `.questions` (opencode question.asked) or `.tool_input.questions` (claude
# AskUserQuestion). ntfy allows 3 buttons max and a question can be
# multi-select/stacked/custom, so buttons only when there is exactly one
# single-select question with 1–3 options: each option becomes a button whose
# POST body is "answer|<label>" (daemon appends "|<req_id>"). Everything else
# stays notify-only — the body carries the full question for reading at the
# terminal. Labels are sanitized (| would corrupt the response-topic format).
# Sets: NOTIFY_MSG, ADAPTER_OPTIONS (full label list for typed replies),
# ADAPTER_ACTIONS (button payload list), ADAPTER_NO_ACTIONS=1 (suppress trio).
#
# Body budget: the ntfy text cap is 4096 bytes; 1500 chars leaves headroom for
# the reply hint and ntfy metadata. Over budget the body is compressed once —
# descriptions dropped, long labels capped — and if that still overflows,
# equal-share keeps every numbered option visible (a reader must always see
# what they are picking). The hint + typed-reply option list are built from
# the raw payload, so answering never depends on the rendered body.
build_question_message() {
  local qcount nopts multiple bc=0 body compressed fit
  local budget=1500
  # the metadata header (core_main prepends it) rides inside the same body
  # budget, so the ntfy cap and the ≤1530 golden assertion still hold
  [ -n "$ALERT_HEADER" ] && budget=$(( budget - ${#ALERT_HEADER} - 2 ))
  body=$(echo "$INPUT" | jq -r '
    def qs: (.questions // .tool_input.questions // []);
    [qs[] |
      ((.header // "Question") + " — " + (.question // "")) +
      (if ((.options // []) | length) > 0 then
        "\n" + ([.options | to_entries[] |
          "\(.key + 1). \(.value.label): \(.value.description // "")"] | join("\n"))
      else "" end)
    ] | join("\n\n")' 2>/dev/null)
  [ -n "$body" ] || body="Question (see terminal)"
  if [ "${#body}" -gt "$budget" ]; then
    # compressed pass: same layout, descriptions dropped, labels capped at 120
    compressed=$(echo "$INPUT" | jq -r '
      def qs: (.questions // .tool_input.questions // []);
      [qs[] |
        ((.header // "Question") + " — " + (.question // "")) +
        (if ((.options // []) | length) > 0 then
          "\n" + ([.options | to_entries[] |
            "\(.key + 1). " + ((.value.label // "") |
              if length > 120 then .[0:117] + "..." else . end)] | join("\n"))
        else "" end)
      ] | join("\n\n")' 2>/dev/null)
    fit=$(printf '%s\n' "$compressed" | fit_question_body "$budget")
    body="${fit:-${body:0:$budget}}"
  fi
  NOTIFY_MSG="$body"

  qcount=$(echo "$INPUT" | jq -r '(.questions // .tool_input.questions // []) | length' 2>/dev/null)
  nopts=$(echo "$INPUT" | jq -r '(.questions // .tool_input.questions // [])[0].options | length' 2>/dev/null)
  multiple=$(echo "$INPUT" | jq -r '(.questions // .tool_input.questions // [])[0].multiple // false' 2>/dev/null)
  if [ "${qcount:-0}" -eq 1 ] && [ "$multiple" = "false" ] && [ "${nopts:-0}" -ge 1 ]; then
    # single-select (any option count): full label list travels in the notify
    # payload so the daemon can map a typed reply ("4" or "D") to a label
    ADAPTER_OPTIONS=$(echo "$INPUT" | jq -c '
      def qs: (.questions // .tool_input.questions // []);
      [qs[0].options[].label | gsub("\\|"; "/")]' 2>/dev/null)
    # hint so the phone knows typing works when tapping doesn't (ntfy caps 3)
    if [ "${nopts:-0}" -le 26 ]; then
      local letter
      letter=$(printf %s abcdefghijklmnopqrstuvwxyz | cut -c "$nopts" | tr '[:lower:]' '[:upper:]')
      NOTIFY_MSG="$NOTIFY_MSG"$'\n\n'"Reply 1-${nopts} (or A-${letter}) to answer"
    else
      NOTIFY_MSG="$NOTIFY_MSG"$'\n\n'"Reply 1-${nopts} to answer"
    fi
    if [ "${nopts:-0}" -le 3 ]; then
      ADAPTER_ACTIONS=$(echo "$INPUT" | jq -c '
        def qs: (.questions // .tool_input.questions // []);
        [qs[0].options[] |
          (.label | gsub("\\|"; "/")) as $l |
          {label: $l, payload: ("answer|" + $l)}]' 2>/dev/null)
    else
      # ntfy caps buttons at 3 — body + typed reply carry 4+ option questions
      ADAPTER_NO_ACTIONS=1
    fi
  else
    # multi-select/stacked: one tap or number cannot compose the answer
    ADAPTER_NO_ACTIONS=1
  fi
  [ -n "$ADAPTER_ACTIONS" ] && bc=$(echo "$ADAPTER_ACTIONS" | jq -r 'length' 2>/dev/null)
  log "question buttons: ${bc:-0} (qcount=${qcount:-?} opts=${nopts:-?} multiple=$multiple no_actions=${ADAPTER_NO_ACTIONS:-0})"
}

# Best-effort focus of the session that owns the pending prompt, run right
# before keystroke injection in a bare terminal. With several sessions of the
# same app open, System Events keystrokes land in whichever window that app
# currently focuses — this selects the prompt's own window/tab first so the
# phone answer reaches the right one (Phase 7 multi-session targeting).
# tmux never reaches here (daemon/watcher send-keys target the pane directly).
# Returns 1 when there is no stable id (Terminal.app, unknown terminals) —
# callers keep the existing frontmost behavior. HOOKLINE_FOCUS_DRY_RUN=1
# prints the command instead of running it (offline tests).
focus_prompt_window() {
  local sid_uuid script
  case "${TERM_PROGRAM:-}" in
    iTerm.app)
      [ -n "${TERM_SESSION_ID:-}" ] || return 1
      # TERM_SESSION_ID is "prefix:UUID" on current iTerm2 (bare UUID on
      # older builds) — the AppleScript session id is the UUID part.
      sid_uuid="${TERM_SESSION_ID##*:}"
      script="tell application \"iTerm2\"
  set want to \"$sid_uuid\"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if (id of s) as string is want then
          select t
          select w
          activate
          return true
        end if
      end repeat
    end repeat
  end repeat
  return false
end tell"
      if [ "${HOOKLINE_FOCUS_DRY_RUN:-0}" = 1 ]; then
        printf 'osascript %s\n' "$script"
        return 0
      fi
      osascript -e "$script" >/dev/null 2>&1
      ;;
    WezTerm)
      [ -n "${WEZTERM_PANE:-}" ] || return 1
      if [ "${HOOKLINE_FOCUS_DRY_RUN:-0}" = 1 ]; then
        printf 'wezterm cli activate-pane --pane-id %s\n' "$WEZTERM_PANE"
        return 0
      fi
      command -v wezterm >/dev/null 2>&1 || return 1
      wezterm cli activate-pane --pane-id "$WEZTERM_PANE" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
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

  # Alert metadata: the provider rides every title (`[claude · session/project]`);
  # project/branch/dir ride a body header line so several concurrent sessions are
  # tellable apart at a glance. HOOKLINE_ALERT_HEADER=0 drops the body line only
  # (privacy) — the title tag always stays.
  BRANCH=""
  ALERT_HEADER=""
  if [ "${HOOKLINE_ALERT_HEADER:-1}" != "0" ]; then
    BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null || true)
    ALERT_HEADER="$PROJECT${BRANCH:+ · $BRANCH} · $CWD"
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

  # Metadata header first, then the adapter's body — one place covers the
  # daemon notify, the legacy direct path, and every question body.
  if [ -n "$ALERT_HEADER" ]; then
    NOTIFY_MSG="$ALERT_HEADER"$'\n\n'"$NOTIFY_MSG"
  fi

  GRACE_PERIOD="${HOOKLINE_GRACE_PERIOD:-20}"
  PHONE_TIMEOUT="${HOOKLINE_PHONE_TIMEOUT:-900}"
  MAX_RETRIES="${HOOKLINE_MAX_RETRIES:-3}"
  # Extended wait: after the phone timeout the watcher stays alive so late
  # answers (including the typed "retry") still land. 0 disables.
  EXTENDED_WAIT="${HOOKLINE_EXTENDED_WAIT:-3600}"
  EXTENDED_INTERVAL="${HOOKLINE_EXTENDED_INTERVAL:-180}"
  [[ "$EXTENDED_WAIT" =~ ^[0-9]+$ ]] || EXTENDED_WAIT=3600
  [[ "$EXTENDED_INTERVAL" =~ ^[0-9]+$ ]] || EXTENDED_INTERVAL=180

  # 4. Register session with daemon (TTY + terminal info for routing; the
  #    provider/transcript/cwd fields feed the typed "context" summary).
  #    ADAPTER_RESPONSE_ONLY=1 (opencode: resolves decisions itself via the
  #    reply API) registers without a pane so the daemon routes the phone
  #    answer through the response file instead of tmux keystrokes.
  if daemon_alive; then
    TMUX_PANE_ID=""
    TMUX_SOCKET_ID=""
    if [ "${ADAPTER_RESPONSE_ONLY:-0}" != 1 ]; then
      TMUX_PANE_ID="${TMUX_PANE:-$(tmux display-message -p '#{pane_id}' 2>/dev/null)}"
      # launchd daemon has no TMUX_TMPDIR, so hand it the socket path —
      # send-keys without -S targets an empty dir. Prefer $TMUX (client env),
      # fall back to the server's own #{socket_path} when the agent strips
      # TMUX from hook children.
      if [ -n "$TMUX_PANE_ID" ]; then
        if [ -n "${TMUX:-}" ]; then
          TMUX_SOCKET_ID="${TMUX%%,*}"
        else
          TMUX_SOCKET_ID=$(tmux display-message -p '#{socket_path}' 2>/dev/null)
        fi
      fi
    fi
    daemon_send "$(jq -nc \
      --arg type "register" \
      --arg session_id "$SESSION_ID" \
      --arg tty "$PARENT_TTY" \
      --arg term_program "${TERM_PROGRAM:-}" \
      --arg tmux_pane "${TMUX_PANE_ID:-}" \
      --arg tmux_socket "${TMUX_SOCKET_ID:-}" \
      --arg provider "$PROVIDER" \
      --arg transcript_path "${TRANSCRIPT_PATH:-}" \
      --arg cwd "$CWD" \
      --arg alert_header "$ALERT_HEADER" \
      '{type:$type,session_id:$session_id,tty:$tty,term_program:$term_program,tmux_pane:$tmux_pane,tmux_socket:$tmux_socket,provider:$provider,transcript_path:$transcript_path,cwd:$cwd,alert_header:$alert_header}')"
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
      if snooze_active; then
        log "background: snooze active, suppressing prompt-expired notification"
        return 0
      fi
      local _topic="${HOOKLINE_TOPIC:-}"
      local _server="${HOOKLINE_NTFY_SERVER:-https://ntfy.sh}"
      [ -z "$_topic" ] && return
      local _msg="No response after ${PHONE_TIMEOUT}s — ${HOOKLINE_WAITING_AGENT} is waiting at the terminal"
      if [ "${EXTENDED_WAIT:-0}" -gt 0 ]; then
        _msg="${_msg}; phone still listening $((EXTENDED_WAIT / 60))m (reply retry)"
      fi
      [ -n "$ALERT_HEADER" ] && _msg="$ALERT_HEADER"$'\n\n'"$_msg"
      local _auth=()
      [ -n "$HOOKLINE_NTFY_USERNAME" ] && _auth=(-u "${HOOKLINE_NTFY_USERNAME}:${HOOKLINE_NTFY_PASSWORD}")
      curl -s "${_auth[@]}" -H "Content-Type: application/json" \
        -d "$(jq -nc \
          --arg topic "$_topic" \
          --arg title "[$PROVIDER · $SESSION_LABEL] Prompt expired" \
          --arg message "$_msg" \
          '{topic:$topic,title:$title,message:$message,priority:2,tags:["hourglass_done"]}')" \
        "${_server}/" &>/dev/null
    }

    # — Snooze: no phone traffic; keep watching for a local answer —
    if snooze_active; then
      log "background: snooze active, prompt stays at terminal — skipping phone notification"
      elapsed=0
      while [ "$elapsed" -lt "$PHONE_TIMEOUT" ]; do
        sleep 1
        elapsed=$((elapsed + 1))
        cur=$(adapter_progress_lines)
        if [ "$cur" -gt "$INITIAL_LINES" ]; then
          log "background: transcript grew ($INITIAL_LINES → $cur lines), user answered locally"
          exit 0
        fi
      done
      log "background: snoozed watcher exiting, prompt stays at terminal"
      exit 0
    fi

    # — Daemon path —
    if daemon_alive; then
      log "background: daemon available, handing off notification"
      # Response files carry approval decisions — non-guessable name (mktemp,
      # 0600) in the user's private TMPDIR so no other local process can plant
      # an "allow". Fallback keeps pid+random for the rare mktemp failure.
      RESPONSE_FILE=$(mktemp "${TMPDIR:-/tmp}/hookline-resp.XXXXXX" 2>/dev/null) \
        || RESPONSE_FILE="${TMPDIR:-/tmp}/hookline-resp.$$.$RANDOM"
      trap 'rm -f "$RESPONSE_FILE"; [[ "$(cat "$LOCK_FILE" 2>/dev/null)" == "$BASHPID" ]] && rm -f "$LOCK_FILE"' EXIT

      retries=0
      current_req_id="$REQ_ID"
      # Notify-only questions (ADAPTER_NO_ACTIONS=1) must suppress the
      # daemon's default Allow/Deny/Retry trio — sent as an explicit flag
      # because permissions also carry an empty actions array.
      notify_no_actions=false
      [ -n "${ADAPTER_NO_ACTIONS:-}" ] && notify_no_actions=true
      while true; do
        rm -f "$RESPONSE_FILE"
        daemon_send "$(jq -nc \
          --arg type "notify" \
          --arg session_id "$SESSION_ID" \
          --arg req_id "$current_req_id" \
          --arg title "[$PROVIDER · $SESSION_LABEL] $TOOL_NAME" \
          --arg message "$NOTIFY_MSG" \
          --arg response_file "$RESPONSE_FILE" \
          --argjson max_retries "$MAX_RETRIES" \
          --argjson actions "${ADAPTER_ACTIONS:-[]}" \
          --argjson options "${ADAPTER_OPTIONS:-[]}" \
          --argjson no_actions "$notify_no_actions" \
          '{type:$type,session_id:$session_id,req_id:$req_id,title:$title,message:$message,response_file:$response_file,max_retries:$max_retries,actions:$actions,options:$options,no_actions:$no_actions}')"

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
          send_timeout_notification
          if [ "$EXTENDED_WAIT" -le 0 ]; then
            log "background: timed out, giving up"
            daemon_send "$(jq -nc --arg type "cancel" --arg req_id "$current_req_id" '{type:$type,req_id:$req_id}')"
            exit 0
          fi
          # Extended wait: the watcher stays alive past the phone timeout so
          # late replies — button taps, typed options, "retry" — still land.
          # Pending daemon entry survives this window; expiry cancels it.
          log "background: phone timeout, extended wait ${EXTENDED_WAIT}s (checks every ${EXTENDED_INTERVAL}s)"
          deadline=$EXTENDED_WAIT
          while [ -z "$decision" ] && [ "$deadline" -gt 0 ]; do
            slice=$EXTENDED_INTERVAL
            [ "$slice" -gt "$deadline" ] && slice=$deadline
            elapsed=0
            while [ "$elapsed" -lt "$slice" ]; do
              sleep 1
              elapsed=$((elapsed + 1))
              cur=$(adapter_progress_lines)
              if [ "$cur" -gt "$INITIAL_LINES" ]; then
                log "background: transcript grew during extended wait, user answered at terminal"
                daemon_send "$(jq -nc --arg type "cancel" --arg req_id "$current_req_id" '{type:$type,req_id:$req_id}')"
                exit 0
              fi
              if [ -f "$RESPONSE_FILE" ]; then
                decision=$(cat "$RESPONSE_FILE")
                rm -f "$RESPONSE_FILE"
                break
              fi
            done
            deadline=$((deadline - slice))
          done
          if [ -z "$decision" ]; then
            log "background: extended wait expired, giving up"
            daemon_send "$(jq -nc --arg type "cancel" --arg req_id "$current_req_id" '{type:$type,req_id:$req_id}')"
            exit 0
          fi
        fi
        log "background: daemon response: $decision"

        # "answer|<label>" is a question-dialog option tapped on the phone
        if [[ "$decision" == answer\|* ]]; then
          adapter_inject "answer" "${decision#answer|}"
          exit 0
        elif [ "$decision" = "allow" ]; then
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
    EXTENDED_WAIT=0   # extended window needs the daemon; legacy unchanged
    log "background: daemon not available, using legacy polling"
    TOPIC="${HOOKLINE_TOPIC:?hookline: HOOKLINE_TOPIC not set in config}"
    NTFY_SERVER="${HOOKLINE_NTFY_SERVER:-https://ntfy.sh}"
    RESPONSE_TOPIC="${TOPIC}-response"

    send_notification() {
      local req_id="$1"
      if snooze_active; then
        log "background: snooze became active, skipping phone notification"
        return 1
      fi
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
      # Action buttons: adapter-provided (question options → "answer|<label>")
      # or the default Allow/Deny/Retry trio. ntfy caps actions at 3.
      # ADAPTER_NO_ACTIONS (notify-only question) sends no buttons at all.
      local _resp_url="${NTFY_SERVER}/${RESPONSE_TOPIC}"
      if [ -n "${ADAPTER_NO_ACTIONS:-}" ]; then
        actions_json='[]'
      elif [ -n "${ADAPTER_ACTIONS:-}" ]; then
        actions_json=$(jq -nc --arg url "$_resp_url" --arg req "$req_id" --argjson acts "$ADAPTER_ACTIONS" \
          '[$acts[] | {action:"http",label:.label,url:$url,method:"POST",body:(.payload + "|" + $req)}]')
      else
        actions_json=$(jq -nc --arg url "$_resp_url" --arg req "$req_id" \
          '[{action:"http",label:"Allow",url:$url,method:"POST",body:("allow|" + $req)},
            {action:"http",label:"Deny",url:$url,method:"POST",body:("deny|" + $req)},
            {action:"http",label:"Retry",url:$url,method:"POST",body:("retry|" + $req)}]')
      fi
      ntfy_resp=$(curl -s "${AUTH_ARGS[@]}" -H "Content-Type: application/json" \
        -d "$(jq -nc \
          --arg topic "$TOPIC" \
          --arg title "[$PROVIDER · $SESSION_LABEL] $TOOL_NAME" \
          --arg message "$NOTIFY_MSG" \
          --argjson actions "$actions_json" \
          '{topic:$topic,title:$title,message:$message,priority:4,tags:["lock"],
            actions:$actions}')" "${NTFY_SERVER}/" 2>&1)
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
            # strip the trailing "|<req_id>"; leaves "allow"/"deny"/"retry"
            # or "answer|<label>" for question-option taps
            DECISION="${MSG%\|"${req_id}"}"
            log "background: phone response: $DECISION"
            return 0
          fi
          # Typed option reply ("4" or "D") on the response topic: map through
          # the question's label list. Single character, single-select only —
          # ADAPTER_OPTIONS is unset for permissions and multi/stacked questions.
          if [ -n "${ADAPTER_OPTIONS:-}" ] && [[ "$MSG" =~ ^[0-9A-Za-z]$ ]]; then
            DECISION=$(jq -r --arg r "$MSG" '
              def toidx($s): if ($s | test("^[0-9]$")) then ($s | tonumber - 1)
                            elif ($s | test("^[a-zA-Z]$")) then (($s | ascii_downcase | explode[0]) - 97)
                            else -1 end;
              (toidx($r)) as $i | select($i >= 0) | (.[$i] // empty) as $l
              | if $l == "" then empty else "answer|" + $l end' \
              <<< "$ADAPTER_OPTIONS" 2>/dev/null)
            if [ -n "$DECISION" ]; then
              log "background: phone response: $DECISION (typed '$MSG')"
              return 0
            fi
          fi
        done <<< "$msgs"
      done
      return 1
    }

    retries=0
    current_req="${REQ_ID}"
    while true; do
      if send_notification "$current_req"; then
        if [[ "$DECISION" == answer\|* ]]; then
          adapter_inject "answer" "${DECISION#answer|}"; break
        elif [ "$DECISION" = "allow" ]; then
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
        if snooze_active; then
          log "background: snoozed before notify went out, prompt stays at terminal"
        else
          log "background: notification timed out, giving up"
          send_timeout_notification
        fi
        break
      fi
    done
  ) &>/dev/null &
  echo "$!" > "$LOCK_FILE"

  log "=== hook complete ==="
  exit 0
}
