#!/bin/bash
# codex adapter — Codex CLI PermissionRequest contract (interim hack, Flow A).
# Codex runs this hook when it is ABOUT to ask for approval. Returning no
# decision (exit 0, empty stdout) declines and codex's own TUI approval menu
# shows; the phone answer then lands as keystrokes into that menu (verified on
# codex 0.157.1: option 1 "Yes, proceed" is preselected → Enter approves,
# Esc cancels). Stdout IS read by codex: the only foreground decision hookline
# emits is allow (safe prefixes — codex already decided to prompt, so a
# read-only command bypasses the menu entirely).
# Registration: install.sh merges a PermissionRequest entry into
# ~/.codex/hooks.json — codex has no settings-JSON hook surface.
# Local-answer signal: the session rollout JSONL (payload transcript_path,
# newest rollout as fallback) grows when the turn resolves locally (tool
# output / turn_aborted); it does not grow while the approval menu sits open.

# shellcheck disable=SC2034  # consumed by install.sh and core.sh

ADAPTER_MATCHER="Bash|apply_patch|mcp__.*"
ADAPTER_RESPONSE_ONLY=1  # daemon's tmux keys are claude-specific — response file only
HOOKLINE_WAITING_AGENT="Codex"

adapter_normalize() {
  ADAPTER_OPTIONS=""
  ADAPTER_ACTIONS=""
  ADAPTER_FREE_TEXT=false
  IS_DONE=""
  # Marks that core's deferred-decision paths run post-input (see
  # adapter_emit_decision): the disabled-flag path fires before this.
  NORMALIZED=1
  TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "Unknown"')
  TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input // {} | tostring' | head -c 300)
  CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
  TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
  # Older payloads may omit transcript_path — fall back to the newest rollout
  # so the local-answer signal still works (empty → progress stays 0).
  if [ -z "$TRANSCRIPT_PATH" ]; then
    # shellcheck disable=SC2012  # rollout filenames are plain ASCII — ls -t is fine
    TRANSCRIPT_PATH=$(ls -t "${HOME}"/.codex/sessions/*/*/*/*.jsonl 2>/dev/null | head -1)
  fi
  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
  if [ "$(echo "$INPUT" | jq -r '.hook_event_name // empty')" = "Stop" ]; then
    codex_normalize_stop
  fi
}

# Stop event = a turn finished (session-done alert). Exits silently (stdout
# empty = codex stops normally) for subagent stops, re-entrant stops, opt-out,
# or a turn shorter than HOOKLINE_DONE_MIN_SECS (the rollout's last
# task_started timestamp is the turn start).
codex_normalize_stop() {
  [ "${HOOKLINE_DONE_ALERTS:-1}" = "0" ] && exit 0
  [ "$(echo "$INPUT" | jq -r '.stop_hook_active // false')" = "true" ] && exit 0
  [ -n "$(echo "$INPUT" | jq -r '.agent_transcript_path // empty')" ] && exit 0
  local start now min="${HOOKLINE_DONE_MIN_SECS:-60}"
  [[ "$min" =~ ^[0-9]+$ ]] || min=60
  start=$(grep '"task_started"' "$TRANSCRIPT_PATH" 2>/dev/null | tail -1 | jq -r '.timestamp // empty' 2>/dev/null)
  if [ -n "$start" ]; then
    start=$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "${start%%.*}" +%s 2>/dev/null \
      || date -u -d "${start%%.*}Z" +%s 2>/dev/null)
    now=$(date +%s)
    [ -n "$start" ] && [ $((now - start)) -lt "$min" ] && exit 0
  fi
  IS_DONE=1
  TOOL_NAME="Done"
  TOOL_INPUT=""
}

# Echo the Bash command ("" = not a Bash tool, or no command extractable).
adapter_command() {
  [ "$TOOL_NAME" = "Bash" ] || return 0
  local cmd
  cmd=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
  printf '%s' "$cmd"
}

# No hookline allowlist to consult: codex's own execution-policy rules already
# ran before PermissionRequest fires (allow/prompt/forbidden decided there),
# so anything reaching this hook was already checked against them.
adapter_allowlist() {
  return 1
}

# Core passes "defer" for two paths with opposite intents (same split as the
# opencode adapter's PERMISSION_ID flag):
#   - disabled-flag path, before adapter_normalize ran → leave stdout empty so
#     codex falls back to its native approval prompt (hookline off = provider
#     default);
#   - safe-prefix path, after normalize → emit allow so the read-only command
#     runs with no menu and no notification.
adapter_emit_decision() {
  if [ "$1" = "defer" ] && [ -n "${NORMALIZED:-}" ]; then
    log "OUTPUT: allow (codex safe prefix — bypass approval menu)"
    jq -nc '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"allow"}}}'
  else
    log "OUTPUT: decline (codex native approval menu owns the UI)"
  fi
}

# No foreground decision: empty stdout = decline → codex shows its approval
# menu, and the background watcher notifies/answers exactly like the claude
# flow does against claude's own menu.
adapter_emit_initial_decision() {
  [ -n "${IS_DONE:-}" ] && { log "OUTPUT: session done (codex Stop, phone flow starting)"; return 0; }
  log "OUTPUT: decline (PermissionRequest — phone flow starting)"
}

adapter_build_message() {
  if [ -n "${IS_DONE:-}" ]; then
    build_done_message "$(echo "$INPUT" | jq -r '
      .last_assistant_message
      | if type == "object" then (.text // .message // "") else (. // "") end' 2>/dev/null)"
    return 0
  fi
  if [ "$TOOL_NAME" = "Bash" ]; then
    _cmd=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
    NOTIFY_MSG="$ ${_cmd:0:280}"
  else
    # apply_patch: prefer codex's human-readable reason, else the patch head.
    _desc=$(echo "$INPUT" | jq -r '.tool_input.description // ""' 2>/dev/null)
    if [ -n "$_desc" ]; then
      NOTIFY_MSG="${TOOL_NAME}: ${_desc:0:280}"
    else
      NOTIFY_MSG="${TOOL_NAME}: ${TOOL_INPUT:0:280}"
    fi
  fi
}

# Monotonic local-user-progress counter: rollout JSONL line count. The rollout
# records the resolution (tool output on allow, turn_aborted on cancel) but
# does not grow while the approval menu waits. Always echoes a number: core's
# -gt comparisons break on empty output.
adapter_progress_lines() {
  local n
  [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ] || { echo "0"; return; }
  n=$(wc -l < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ')
  echo "${n:-0}"
}

# allow → Enter (key code 36): option 1 "Yes, proceed" is preselected, so no
# digit is needed. deny → Escape (key code 53): cancels the menu regardless of
# option count (claude uses the same escape hatch).
# Inside tmux, inject with `tmux send-keys` into the hook's own pane (codex's
# pane — the hook is codex's child): focus-independent, works attached or
# detached. The daemon can't do this for us — its tmux keys are claude-specific
# (1/Enter, Esc) — hence ADAPTER_RESPONSE_ONLY=1 with watcher-side injection.
# Bare terminals fall back to frontmost-app osascript (claude's non-tmux path:
# the approval menu must be focused for a phone answer to matter at all).
adapter_inject() {
  local action="$1" label="$2" key
  if [ -n "${IS_DONE:-}" ]; then
    codex_inject_prompt "$action" "$label"
    return 0
  fi
  case "$action" in
    deny) key="Escape" ;;
    *)    key="Enter" ;;
  esac
  if [ -n "${TMUX_PANE:-}" ] && command -v tmux &>/dev/null; then
    log "background: injecting '$action' ($label) via tmux send-keys to pane $TMUX_PANE"
    tmux send-keys -t "$TMUX_PANE" "$key" 2>/dev/null
  else
    log "background: injecting '$action' ($label) via frontmost app (osascript)"
    focus_prompt_window || true
    if [ "$action" = "deny" ]; then
      osascript -e 'tell application "System Events" to key code 53' 2>/dev/null
    else
      osascript -e 'tell application "System Events" to key code 36' 2>/dev/null
    fi
  fi
}

# Session-done reply: type the prompt into codex's idle composer and submit.
# 'go' (label Continue) sends the standing continue text; 'do <text>' arrives
# as the label itself. Newlines flatten so Enter is the only submit.
codex_inject_prompt() {
  local action="$1" label="$2" text
  [ "$action" = "answer" ] || { log "background: ignoring '$action' for session-done alert"; return 0; }
  text="$label"
  [ "$text" = "Continue" ] && text="$DONE_CONTINUE_TEXT"
  text=$(printf '%s' "$text" | tr '\n' ' ')
  if [ -n "${TMUX_PANE:-}" ] && command -v tmux &>/dev/null; then
    log "background: typing continue prompt via tmux send-keys to pane $TMUX_PANE"
    tmux send-keys -t "$TMUX_PANE" -l -- "$text" 2>/dev/null
    tmux send-keys -t "$TMUX_PANE" Enter 2>/dev/null
  else
    log "background: typing continue prompt via frontmost app (osascript)"
    focus_prompt_window || true
    text=${text//\\/\\\\}
    text=${text//\"/\\\"}
    osascript -e "tell application \"System Events\" to keystroke \"$text\"" \
      -e 'tell application "System Events" to key code 36' 2>/dev/null
  fi
}
