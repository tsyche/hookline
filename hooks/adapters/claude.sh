#!/bin/bash
# claude adapter — Claude Code + blackbox (~/.claude-bb) PreToolUse contract.
# Sourced by hooks/hookline.sh after core.sh. Supplies the provider side of the
# adapter interface: stdin payload normalization, permissionDecision JSON,
# permissions.allow[] parsing, notification message wording, transcript-based
# progress signal, and the terminal menu injection profile.

# shellcheck disable=SC2034  # consumed by install.sh and core.sh

ADAPTER_MATCHER="Bash|Edit|Write|NotebookEdit|AskUserQuestion"
HOOKLINE_WAITING_AGENT="Claude"
SETTINGS_GLOBAL="${HOME}/.claude/settings.json"
SETTINGS_LOCAL="${CWD:+$CWD/.claude/settings.local.json}"
SETTINGS_LOCAL="${SETTINGS_LOCAL:-${HOME}/.claude/settings.local.json}"

adapter_normalize() {
  TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "Unknown"')
  TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input // {} | tostring' | head -c 300)
  CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
  TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
}

# Echo the Bash command ("" = not a Bash tool, or no command extractable).
adapter_command() {
  [ "$TOOL_NAME" = "Bash" ] || return 0
  local cmd
  cmd=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
  [ -z "$cmd" ] && cmd="$TOOL_INPUT"
  printf '%s' "$cmd"
}

# Return 0 if the command matches a permissions.allow[] pattern in the global
# or local settings file — logs the match and emits the defer decision itself.
adapter_allowlist() {
  local cmd="$1" _settings_file patterns pattern prefix
  for _settings_file in "$SETTINGS_GLOBAL" "$SETTINGS_LOCAL"; do
    [ -f "$_settings_file" ] || continue
    patterns=$(jq -r '.permissions.allow[] | select(startswith("Bash(")) | sub("Bash\\("; "") | sub("\\)$"; "")' "$_settings_file" 2>/dev/null)
    while IFS= read -r pattern; do
      [ -z "$pattern" ] && continue
      if [[ "$pattern" == *\* ]]; then
        prefix="${pattern%\*}"
        if [[ "$cmd" == "$prefix"* ]]; then
          log "matches allowlist pattern in $_settings_file: Bash($pattern) → defer silently"
          adapter_emit_decision defer
          return 0
        fi
      else
        if [ "$cmd" = "$pattern" ]; then
          log "matches allowlist pattern (exact) in $_settings_file: Bash($pattern) → defer silently"
          adapter_emit_decision defer
          return 0
        fi
      fi
    done <<< "$patterns"
  done
  return 1
}

adapter_emit_decision() {
  jq -nc --arg d "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d}}'
}

adapter_emit_initial_decision() {
  if [ "$TOOL_NAME" = "AskUserQuestion" ]; then
    log "OUTPUT: defer (AskUserQuestion — multi-option picker)"
    adapter_emit_decision defer
  else
    log "OUTPUT: ask"
    adapter_emit_decision ask
  fi
}

adapter_build_message() {
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
}

# Monotonic local-user-progress counter: transcript line count. Growth between
# two reads means the user answered the prompt at the terminal.
adapter_progress_lines() {
  wc -l < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ' || echo "0"
}

# allow → type "1" + Enter (option 1 is always "Yes")
# deny  → Escape (key code 53), which cancels the prompt regardless of how
#         many options the menu has — "3" breaks on 2-option menus.
adapter_inject() {
  local action="$1"   # "allow" or "deny"
  local label="$2"
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
