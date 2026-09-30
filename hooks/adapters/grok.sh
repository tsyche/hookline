#!/bin/bash
# grok adapter — Grok CLI PreToolUse contract (claude-compatible hook surface).
# Sourced by hooks/hookline.sh after core.sh. grok reads the claude
# hookSpecificOutput decision shape verbatim (probed on grok 1.0.44: ask forces
# grok's permission card even when a claude-compat allow rule would run the
# call; defer lets grok's own rules decide). The registered matcher tests grok's
# native tool names (Bash → run_terminal_command, Write → write, AskUserQuestion
# → ask_user_question) — an anchored alternation so an MCP server__tool name
# containing "write" cannot match. Global ~/.grok/hooks/*.json handlers run
# without a trust step.
# Registration: install.sh writes a PreToolUse entry into
# ~/.grok/hooks/hookline.json — separate from config.toml, user config untouched.
#
# Permission-card keys (probed on grok 1.0.44):
#   allow  → the allow-once row's digit. Row order varies by prompt class
#            (bash 5 rows / "Yes, proceed", edit 4 rows / "Yes", ask 4 rows /
#            "allow once" — row 3 under default config, but drops when
#            remember_tool_approvals is off), so the row is parsed off the pane
#            screen instead of hardcoded. The focused row defaults to
#            always-approve, so Enter is never safe; a parse miss injects
#            nothing and logs.
#   deny   → Ctrl+C (Esc only parks focus — it never answers).
#   answer → the option's digit only: the card auto-advances between questions
#            and auto-submits on the last one — an extra Enter lands in the
#            composer.
# Response-only like codex: the daemon's tmux keys are claude-specific
# (1/Enter, Esc — "1" is grok's always-approve row), so the session registers
# without a pane and the watcher injects itself — tmux send-keys into the hook's
# own pane, frontmost-app osascript otherwise.
# Local-answer signal: the updates.jsonl transcript (payload transcript_path)
# grows when the turn resolves (tool output / answered card) and does not grow
# while a card sits open.
#
# shellcheck disable=SC2034  # consumed by install.sh and core.sh

ADAPTER_MATCHER='^(Bash|run_terminal_command|Edit|Write|MultiEdit|search_replace|write|edit|NotebookEdit|notebook_edit|AskUserQuestion|ask_user_question)$'
ADAPTER_RESPONSE_ONLY=1  # daemon's tmux keys are claude-specific — response file only
HOOKLINE_WAITING_AGENT="Grok"
# grok merges claude-compat permission rules from these files, so hookline's
# allowlist source is the same one claude consults.
SETTINGS_GLOBAL="${HOME}/.claude/settings.json"
SETTINGS_LOCAL="${CWD:+$CWD/.claude/settings.local.json}"
SETTINGS_LOCAL="${SETTINGS_LOCAL:-${HOME}/.claude/settings.local.json}"

adapter_normalize() {
  NORMALIZED=1
  TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "Unknown"')
  TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input // {} | tostring' | head -c 300)
  CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
  TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
  # question flow state (build_question_message in core.sh fills the pieces it
  # needs; permissions leave these empty → default trio, no typed options)
  IS_QUESTION=""
  ADAPTER_ACTIONS=""
  ADAPTER_NO_ACTIONS=""
  ADAPTER_OPTIONS=""
  [ "$TOOL_NAME" = "ask_user_question" ] && IS_QUESTION=1
}

# Echo the shell command ("" = not a shell tool, or no command extractable).
adapter_command() {
  case "$TOOL_NAME" in
    Bash|run_terminal_command) ;;
    *) return 0 ;;
  esac
  local cmd
  cmd=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
  [ -z "$cmd" ] && cmd="$TOOL_INPUT"
  printf '%s' "$cmd"
}

# Return 0 if the command matches a permissions.allow[] pattern in the global
# or local claude settings file (grok loads the same rules) — logs the match
# and emits the defer decision itself.
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
  if [ -n "$IS_QUESTION" ]; then
    log "OUTPUT: defer (ask_user_question — multi-option picker)"
    adapter_emit_decision defer
  else
    log "OUTPUT: ask"
    adapter_emit_decision ask
  fi
}

adapter_build_message() {
  case "$TOOL_NAME" in
    Bash|run_terminal_command)
      _cmd=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
      NOTIFY_MSG="$ ${_cmd:0:280}"
      ;;
    Write|write|Edit|edit|MultiEdit|search_replace)
      _path=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
      NOTIFY_MSG="${TOOL_NAME}: $_path"
      ;;
    NotebookEdit|notebook_edit)
      _path=$(echo "$INPUT" | jq -r '.tool_input.path // ""' 2>/dev/null)
      NOTIFY_MSG="${TOOL_NAME}: $_path"
      ;;
    ask_user_question)
      # question dialog — shared builder: body with numbered options, option
      # buttons (≤3), typed-reply hint + ADAPTER_OPTIONS for 4+
      build_question_message
      ;;
    *)
      NOTIFY_MSG="${TOOL_INPUT:0:300}"
      ;;
  esac
}

# Monotonic local-user-progress counter: raw updates.jsonl line count. The
# transcript records the resolution (tool output / card answer) and does not
# grow while a card waits. Always echoes a number: core's -gt comparisons break
# on empty output.
adapter_progress_lines() {
  local n
  [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ] || { echo "0"; return; }
  n=$(wc -l < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ')
  echo "${n:-0}"
}

# Parse the allow-once row digit out of a card screenshot (stdin). Row labels
# differ per prompt class — "Yes, proceed" (bash), "Yes" (edit/write),
# "allow once" (ask) — all end their row; the prefix carries box borders
# (┃) and the suffix may hold scrollbar glyphs, so both sides match non-row
# bytes only, and a trailing label must not continue into letters ("Yes, and
# don't ask again…" must not parse as "Yes"). Prints nothing when no row
# matches: callers must not guess a digit.
grok_allow_digit() {
  sed -nE 's/^[^0-9]*([0-9]+) \([^)]*\) (Yes, proceed|Yes|allow once)[^A-Za-z0-9]*$/\1/p' | head -1
}

# Screenshot of the card's pane/screen ("" = unreadable). tmux first, then the
# bare-terminal backends: iTerm2 session contents, Terminal.app selected tab,
# WezTerm focused pane (WEZTERM_PANE when set, else the focused pane from
# `wezterm cli list`). Unknown terminals, a missing wezterm binary, or a
# failed read echo nothing — callers must treat "" as "no screen" and inject
# nothing (the prompt stays for the user to answer by hand).
grok_screen() {
  local pane
  if [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
    tmux capture-pane -p -t "$TMUX_PANE" 2>/dev/null
    return
  fi
  case "${TERM_PROGRAM:-}" in
    iTerm.app)
      osascript 2>/dev/null <<'EOF'
tell application "iTerm2"
  tell current session of current window to get contents
end tell
EOF
      ;;
    Apple_Terminal)
      osascript -e 'tell application "Terminal" to get contents of selected tab of front window' 2>/dev/null
      ;;
    WezTerm)
      command -v wezterm >/dev/null 2>&1 || return 0
      pane="${WEZTERM_PANE:-}"
      if [ -z "$pane" ]; then
        pane=$(wezterm cli list --format json 2>/dev/null \
          | jq -r '[.[] | select(.is_focused == true)][0].pane_id // empty' 2>/dev/null)
      fi
      [ -n "$pane" ] || return 0
      wezterm cli get-text --pane-id "$pane" 2>/dev/null
      ;;
  esac
}

# allow   → parse the allow-once digit off the card and type it (Enter would
#           hit the always-approve preselect; a parse miss injects nothing)
# deny    → Ctrl+C (cancels the card regardless of row count — the claude
#           Escape equivalent; Esc only parks focus in grok)
# answer  → question option digit, no Enter (the card auto-advances/auto-submits)
adapter_inject() {
  local action="$1" label="$2" digit="" screen
  local proc=""
  case "${TERM_PROGRAM:-}" in
    iTerm.app)      proc="iTerm2" ;;
    Apple_Terminal) proc="Terminal" ;;
    WezTerm)        proc="WezTerm" ;;
  esac
  case "$action" in
    answer)
      digit=$(echo "${ADAPTER_OPTIONS:-[]}" | jq -r --arg l "$label" \
        'index($l) // -1 | . + 1' 2>/dev/null)
      if [ -z "$digit" ] || [ "$digit" -le 0 ] 2>/dev/null; then
        log "background: answer label '$label' not in option list, ignoring"
        return 0
      fi
      ;;
    deny) ;;
    *)
      screen=$(grok_screen)
      digit=$(printf '%s\n' "$screen" | grok_allow_digit)
      if [ -z "$digit" ]; then
        log "background: allow-once row not found on grok card, not injecting"
        return 0
      fi
      ;;
  esac
  if [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
    log "background: injecting '$action' ($label) via tmux send-keys to pane $TMUX_PANE"
    if [ "$action" = "deny" ]; then
      tmux send-keys -t "$TMUX_PANE" C-c 2>/dev/null
    else
      tmux send-keys -t "$TMUX_PANE" "$digit" 2>/dev/null
    fi
  else
    log "background: injecting '$action' ($label) via frontmost app (osascript)"
    focus_prompt_window || true
    if [ -n "$proc" ]; then
      if [ "$action" = "deny" ]; then
        osascript -e "tell application \"System Events\" to tell process \"$proc\" to keystroke \"c\" using control down" 2>/dev/null
      else
        osascript -e "tell application \"System Events\" to tell process \"$proc\" to keystroke \"$digit\"" 2>/dev/null
      fi
    else
      if [ "$action" = "deny" ]; then
        osascript -e 'tell application "System Events" to keystroke "c" using control down' 2>/dev/null
      else
        osascript -e "tell application \"System Events\" to keystroke \"$digit\"" 2>/dev/null
      fi
    fi
  fi
}
