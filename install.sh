#!/bin/bash
set -e

REPO="$(cd "$(dirname "$0")" && pwd)"
HOOK_SRC="${REPO}/hooks/hookline.sh"
HOOK_DST="${HOME}/.local/share/hookline/hooks/hookline.sh"
DAEMON_SRC="${REPO}/daemon/hookline-daemon"
DAEMON_DST="${HOME}/.local/share/hookline/daemon/hookline-daemon"
PLIST_SRC="${REPO}/daemon/com.hookline.daemon.plist"
PLIST_LABEL="com.hookline.daemon"
PLIST_DST="${HOME}/Library/LaunchAgents/${PLIST_LABEL}.plist"
CONFIG_DIR="${HOME}/.config/hookline"
CONFIG_FILE="${CONFIG_DIR}/config"
LOG_DIR="${HOME}/.local/share/hookline"
SETTINGS="${HOME}/.claude/settings.json"

echo "=== hookline installer ==="
echo

# Check dependencies
for cmd in jq curl python3; do
  command -v "$cmd" &>/dev/null || { echo "Error: $cmd is required but not installed."; exit 1; }
done

# macOS: check osascript for keystroke injection
if [[ "$OSTYPE" == "darwin"* ]]; then
  command -v osascript &>/dev/null || echo "Warning: osascript not found — keystroke injection disabled."
fi

# Check dependencies
command -v python3 &>/dev/null || { echo "Error: python3 is required but not installed."; exit 1; }

# Create directories
mkdir -p "$(dirname "$HOOK_DST")" "$(dirname "$DAEMON_DST")" "$CONFIG_DIR" "$LOG_DIR" \
         "${HOME}/Library/LaunchAgents"

# Configure topic
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

if [ -z "$HOOKLINE_TOPIC" ]; then
  echo -n "Enter ntfy topic name (leave blank to generate): "
  read -r topic
  if [ -z "$topic" ]; then
    topic="hookline-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 12)"
    echo "Generated topic: $topic"
  fi
  HOOKLINE_TOPIC="$topic"
fi

# Write config
cat > "$CONFIG_FILE" <<EOF
HOOKLINE_TOPIC="${HOOKLINE_TOPIC}"
HOOKLINE_NTFY_SERVER="https://ntfy.sh"
HOOKLINE_GRACE_PERIOD=20
HOOKLINE_PHONE_TIMEOUT=900
EOF
chmod 600 "$CONFIG_FILE"
echo "Config written to $CONFIG_FILE"

# Install hook
cp "$HOOK_SRC" "$HOOK_DST"
chmod +x "$HOOK_DST"
echo "Hook installed to $HOOK_DST"

# Install CLI
CLI_SRC="${REPO}/hookline"
CLI_DST="/usr/local/bin/hookline"
if [ -f "$CLI_SRC" ]; then
  cp "$CLI_SRC" "$CLI_DST" 2>/dev/null && chmod +x "$CLI_DST" && echo "CLI installed to $CLI_DST" \
    || echo "Warning: could not install to $CLI_DST (try sudo). Run ./hookline directly instead."
fi

# Install daemon
cp "$DAEMON_SRC" "$DAEMON_DST"
chmod +x "$DAEMON_DST"
echo "Daemon installed to $DAEMON_DST"

# Install and register launchd plist
sed -e "s|HOOKLINE_DAEMON_PATH|$CLI_DST|g" \
    -e "s|HOOKLINE_LOG_DIR|$LOG_DIR|g" \
    "$PLIST_SRC" > "$PLIST_DST"
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"
echo "Daemon registered with launchd and started"

# Register hook in Claude Code settings
if [ -f "$SETTINGS" ]; then
  # Check if hookline is already registered
  if jq -e '.hooks.PreToolUse[]? | select(.hooks[]?.command? | contains("hookline"))' "$SETTINGS" &>/dev/null; then
    echo "Hook already registered in $SETTINGS"
  else
    jq --arg hook "$HOOK_DST" '
      .hooks //= {} |
      .hooks.PreToolUse //= [] |
      .hooks.PreToolUse += [{
        "matcher": "Bash|Edit|Write|NotebookEdit|AskUserQuestion",
        "hooks": [{"type": "command", "command": $hook, "timeout": 310}]
      }]
    ' "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
    echo "Hook registered in $SETTINGS"
  fi
else
  echo "Warning: $SETTINGS not found — register the hook manually."
  echo "Add to ~/.claude/settings.json:"
  echo '  "hooks": {"PreToolUse": [{"matcher": "Bash|Edit|Write|NotebookEdit|AskUserQuestion", "hooks": [{"type": "command", "command": "'"$HOOK_DST"'", "timeout": 310}]}]}'
fi

echo
echo "=== Installation complete ==="
echo "Subscribe to topic '${HOOKLINE_TOPIC}' in the ntfy app on your phone."
echo "Run 'hookline status' to verify everything is running."
echo "Run 'bash scripts/test.sh' to send a test notification."
