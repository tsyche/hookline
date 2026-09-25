#!/bin/bash
# opencode adapter — OpenCode permission contract. Unlike claude, opencode has
# no settings-JSON hook: the opencode plugin (hooks/plugins/hookline.js,
# installed to ~/.config/opencode/plugins/) sees `permission.asked`, spawns
# `hookline.sh opencode` with the permission object on stdin, and the native
# TUI prompt is already showing. This adapter's decisions are therefore side
# effects: a unix-socket handoff (HOOKLINE_OPC_REPLY_SOCK) to the plugin, which
# POSTs via its in-process SDK client — opencode's serverUrl does not answer
# plain TCP (curl gets ECONNREFUSED). Stdout stays empty by contract.
# Local-answer signal: the plugin appends a line to
# ~/.local/share/hookline/opencode-answered-<sessionID> on `permission.replied`,
# which adapter_progress_lines reports as growth.

# shellcheck disable=SC2034  # consumed by install.sh and core.sh

ADAPTER_MATCHER=""   # no settings-file registration — plugin file instead
ADAPTER_RESPONSE_ONLY=1  # daemon routes answers via response file, not tmux keys
HOOKLINE_WAITING_AGENT="OpenCode"

adapter_normalize() {
  TOOL_NAME=$(echo "$INPUT" | jq -r '.permission // "Unknown"')
  TOOL_INPUT=$(echo "$INPUT" | jq -r '.metadata // {} | tostring' | head -c 300)
  CWD="${HOOKLINE_OPC_CWD:-$PWD}"
  TRANSCRIPT_PATH=""
  SESSION_ID=$(echo "$INPUT" | jq -r '.sessionID // empty')
  PERMISSION_ID=$(echo "$INPUT" | jq -r '.id // empty')
}

# Echo the bash command ("" = not a bash permission, or no command).
adapter_command() {
  [ "$TOOL_NAME" = "bash" ] || return 0
  echo "$INPUT" | jq -r '.metadata.command // ""' 2>/dev/null
}

# No settings allowlist to consult: opencode only emits permission.asked for
# rules its own config resolved to "ask" — allow/deny already happened.
adapter_allowlist() {
  return 1
}

# Decisions are reply-API side effects; stdout is not read by the provider.
# Two callers pass "defer":
#   - core's disabled-flag path, before adapter_normalize ran → log only and
#     leave the native prompt alone (hookline off = provider default);
#   - core's safe-prefix/allowlist path, after normalize → auto-approve via
#     reply "once" (README contract: safe commands approved with no prompt
#     and no notification; the visible prompt dismisses itself).
adapter_emit_decision() {
  if [ "$1" = "defer" ] && [ -n "${PERMISSION_ID:-}" ]; then
    log "OUTPUT: auto-approve (opencode safe prefix/allowlist)"
    adapter_inject allow "auto-approve"
  else
    log "OUTPUT: defer (opencode — disabled, native prompt owns the UI)"
  fi
}

adapter_emit_initial_decision() {
  log "OUTPUT: prompt active (opencode native permission prompt, phone flow starting)"
}

adapter_build_message() {
  if [ "$TOOL_NAME" = "bash" ]; then
    _cmd=$(echo "$INPUT" | jq -r '.metadata.command // ""' 2>/dev/null)
    NOTIFY_MSG="$ ${_cmd:0:280}"
  else
    _pat=$(echo "$INPUT" | jq -r '.patterns[0] // ""' 2>/dev/null)
    NOTIFY_MSG="${TOOL_NAME}: ${_pat:0:280}"
  fi
}

# Monotonic local-user-progress counter. The plugin appends one line per
# permission.replied (local or programmatic); growth = answered at terminal.
# Always echoes a number: an unreadable/absent file must not break core's
# numeric -gt comparisons (empty string makes `[ ... -gt ... ]` error out).
adapter_progress_lines() {
  local n
  n=$(wc -l < "${HOME}/.local/share/hookline/opencode-answered-${SESSION_ID}" 2>/dev/null | tr -d ' ')
  echo "${n:-0}"
}

# allow → reply "once"; deny → reply "reject" — resolves the pending prompt.
# The decision is routed over HOOKLINE_OPC_REPLY_SOCK to the opencode plugin,
# whose in-process SDK client POSTs it: opencode's serverUrl is not reachable
# over plain TCP (curl gets ECONNREFUSED), only the plugin's client can answer.
# A dead bridge (TUI exited) is logged and ignored.
adapter_inject() {
  local action="$1" label="$2" response
  case "$action" in
    allow) response="once" ;;
    deny)  response="reject" ;;
    *)     return 0 ;;
  esac
  if [ -z "${HOOKLINE_OPC_REPLY_SOCK:-}" ] || [ -z "$SESSION_ID" ] || [ -z "$PERMISSION_ID" ]; then
    log "background: cannot reply — missing reply socket/session/permission id"
    return 0
  fi
  log "background: routing '$response' ($label) for $PERMISSION_ID to plugin bridge"
  local payload errf rc
  payload=$(jq -nc --arg r "$response" --arg sid "$SESSION_ID" --arg pid "$PERMISSION_ID" \
    '{response:$r,session_id:$sid,permission_id:$pid}' 2>/dev/null)
  errf="${HOME}/.local/share/hookline/inject-err.txt"
  if "$PYBIN" -c "
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(3)
try:
    s.connect('${HOOKLINE_OPC_REPLY_SOCK}')
    s.sendall(sys.stdin.buffer.read())
    s.shutdown(socket.SHUT_WR)
    s.recv(64)
    sys.exit(0)
except Exception as e:
    print(type(e).__name__ + ': ' + str(e), file=sys.stderr)
    sys.exit(1)
finally:
    s.close()
" <<< "$payload" 2>"$errf"; then
    log "background: plugin accepted reply '$response'"
  else
    rc=$?
    log "background: plugin bridge rc=$rc err=$(tr -d '\n' < "$errf" 2>/dev/null) — leaving prompt to the terminal"
  fi
}
