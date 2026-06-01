#!/bin/bash
# hookline — Claude Code PreToolUse hook → ntfy.sh remote approval
# Shows terminal prompt immediately; sends phone notification after grace period.
# If phone response arrives, keystroke injection dismisses the terminal prompt.
# Answer from terminal or phone — whichever is convenient.

CONFIG_FILE="${HOME}/.config/hookline/config"
LOG_FILE="${HOME}/.local/share/hookline/hookline.log"
SETTINGS_LOCAL="${CWD:+$CWD/../.claude/settings.local.json}"
SETTINGS_LOCAL="${SETTINGS_LOCAL:-${HOME}/.claude/settings.local.json}"

log() {
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${REQ_ID:-init}" "$*" >> "$LOG_FILE"
}

source "$CONFIG_FILE" 2>/dev/null || { echo "config not found"; exit 0; }

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "Unknown"')
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input // {} | tostring' | head -c 300)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
PROJECT=$(basename "$CWD" 2>/dev/null || echo "unknown")
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

REQ_ID="$(date +%s)-$$"
PARENT_TTY=$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ')

log "=== PreToolUse hook fired ==="
log "tool: $TOOL_NAME | parent_tty: $PARENT_TTY"
log "transcript_path: $TRANSCRIPT_PATH"
log "session_id: $SESSION_ID"

# 1. Check if tool/input matches a pattern in project's allowlist (skip notification entirely)
SHOULD_NOTIFY=true

# Built-in safe-command prefixes
SAFE_PREFIXES=("echo " "stat " "ls " "pwd " "pwd" "cat " "grep " "find " "date " "whoami " "hostname " "uname " "which " "type " "file " "head " "tail " "wc " "sort " "uniq " "cut " "tr ")

if [ "$TOOL_NAME" = "Bash" ]; then
  # Extract actual command from Bash input JSON
  cmd=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
  [ -z "$cmd" ] && cmd="$TOOL_INPUT"

  log "extracted bash command: $cmd"

  # Check built-in safe prefixes
  for prefix in "${SAFE_PREFIXES[@]}"; do
    if [[ "$cmd" == "$prefix"* ]]; then
      log "matches safe prefix: $prefix → defer silently"
      jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"defer"}}'
      exit 0
    fi
  done

  # Check project's allowlist patterns
  if [ -f "$SETTINGS_LOCAL" ]; then
    patterns=$(jq -r '.permissions.allow[] | select(startswith("Bash(")) | sub("Bash\\("; "") | sub("\\)$"; "")' "$SETTINGS_LOCAL" 2>/dev/null)
    while IFS= read -r pattern; do
      [ -z "$pattern" ] && continue
      if [[ "$pattern" == *\* ]]; then
        prefix="${pattern%\*}"
        if [[ "$cmd" == "$prefix"* ]]; then
          log "matches allowlist pattern: Bash($pattern) → defer silently"
          jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"defer"}}'
          exit 0
        fi
      else
        if [ "$cmd" = "$pattern" ]; then
          log "matches allowlist pattern (exact): Bash($pattern) → defer silently"
          jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"defer"}}'
          exit 0
        fi
      fi
    done <<< "$patterns"
  fi
fi

# 2. OUTPUT ASK IMMEDIATELY (this is the decision that shows terminal prompt)
log "OUTPUT: ask"
jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask"}}'

# 3. Now do the async work: send notification + listen for phone + inject keystroke
# This runs in background AFTER the hook has already output its decision
TOPIC="${HOOKLINE_TOPIC:?hookline: HOOKLINE_TOPIC not set in config}"
NTFY_SERVER="${HOOKLINE_NTFY_SERVER:-https://ntfy.sh}"
RESPONSE_TOPIC="${TOPIC}-response"
PHONE_TIMEOUT="${HOOKLINE_PHONE_TIMEOUT:-60}"
GRACE_PERIOD="${HOOKLINE_GRACE_PERIOD:-20}"

# Build human-readable notification message (instead of raw JSON blob)
if [ "$TOOL_NAME" = "Bash" ]; then
  _cmd=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
  NOTIFY_MSG="$ ${_cmd:0:280}"
elif [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; then
  _path=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
  NOTIFY_MSG="${TOOL_NAME}: $_path"
elif [ "$TOOL_NAME" = "NotebookEdit" ]; then
  _path=$(echo "$INPUT" | jq -r '.tool_input.path // ""' 2>/dev/null)
  NOTIFY_MSG="NotebookEdit: $_path"
else
  NOTIFY_MSG="${TOOL_INPUT:0:300}"
fi

# Transcript line count is captured AFTER 1s buffer (inside background) to let
# Claude Code finish writing the tool_use line before we baseline.

(
  # Phase 1: Send initial notification and listen for response
  send_initial_notification() {
    log "background: sending initial phone notification..."
    curl -s -H "Content-Type: application/json" \
      -d "$(jq -nc \
        --arg topic "$TOPIC" \
        --arg title "[$PROJECT] $TOOL_NAME" \
        --arg message "$NOTIFY_MSG" \
        --arg url "${NTFY_SERVER}/${RESPONSE_TOPIC}" \
        '{
          topic: $topic, title: $title, message: $message,
          priority: 4, tags: ["lock"],
          actions: [
            {action:"http",label:"Allow",url:$url,method:"POST",body:"allow|'$REQ_ID'"},
            {action:"http",label:"Deny",url:$url,method:"POST",body:"deny|'$REQ_ID'"},
            {action:"http",label:"Retry",url:$url,method:"POST",body:"retry|'$REQ_ID'"}
          ]
        }')" "${NTFY_SERVER}/" > /tmp/ntfy-response-$REQ_ID.json 2>&1
    response_id=$(cat /tmp/ntfy-response-$REQ_ID.json 2>/dev/null | jq -r '.id // "NO_ID"')
    log "notification sent, response id: $response_id"

    log "background: polling for phone response (${PHONE_TIMEOUT}s)..."
    DECISION=""
    local elapsed=0
    local since_id="$response_id"
    while [ "$elapsed" -lt "$PHONE_TIMEOUT" ]; do
      sleep 3
      elapsed=$((elapsed + 3))
      # Poll for new messages since the notification was sent
      msgs=$(curl -s --max-time 5 \
        "${NTFY_SERVER}/${RESPONSE_TOPIC}/json?poll=1&since=${since_id}" 2>/dev/null)
      while IFS= read -r msg; do
        [ -z "$msg" ] && continue
        msg_id=$(echo "$msg" | jq -r '.id // empty' 2>/dev/null)
        MSG=$(echo "$msg" | jq -r '.message // empty' 2>/dev/null)
        [ -n "$msg_id" ] && since_id="$msg_id"
        if [[ "$MSG" == *"|$REQ_ID" ]]; then
          DECISION="${MSG%%|*}"
          log "background: phone response: $DECISION"
          return 0
        fi
      done <<< "$msgs"
    done

    return 1  # Timeout (no response)
  }

  # Handle decision (allow/deny)
  handle_decision() {
    local decision="$1"
    if [ "$decision" = "allow" ]; then
      log "background: injecting keystroke '1' + Enter (Allow)"
      osascript -e "tell application \"System Events\" to tell process \"iTerm2\" to keystroke \"1\"" -e "tell application \"System Events\" to key code 36" 2>/dev/null
    elif [ "$decision" = "deny" ]; then
      log "background: injecting keystroke '3' + Enter (Deny)"
      osascript -e "tell application \"System Events\" to tell process \"iTerm2\" to keystroke \"3\"" -e "tell application \"System Events\" to key code 36" 2>/dev/null
    fi
  }

  # Main flow: 1s buffer (let tool_use line settle), baseline line count,
  # then 20s grace period, then send notification.
  sleep 1
  INITIAL_LINES=$(wc -l < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ' || echo "0")
  log "background: baseline transcript lines: $INITIAL_LINES, starting ${GRACE_PERIOD}s grace period..."
  sleep "$GRACE_PERIOD"

  CURRENT_LINES=$(wc -l < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ' || echo "0")
  if [ "$CURRENT_LINES" -gt "$INITIAL_LINES" ]; then
    log "background: transcript grew ($INITIAL_LINES → $CURRENT_LINES lines), user answered locally, exiting"
    exit 0
  fi
  log "background: no new transcript lines, user likely away - sending notification"

  # Send notification; loop on timeout or manual Retry tap
  while true; do
    if send_initial_notification; then
      if [ "$DECISION" = "retry" ]; then
        log "background: user tapped Retry, resending..."
      else
        handle_decision "$DECISION"
        break
      fi
    else
      log "background: notification timed out, resending..."
    fi
  done
) &>/dev/null &

log "=== hook complete ==="
exit 0
