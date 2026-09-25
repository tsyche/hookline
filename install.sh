#!/bin/bash
set -e

REPO="$(cd "$(dirname "$0")" && pwd)"
HOOK_SRC_DIR="${REPO}/hooks"
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
SETTINGS_BB="${HOME}/.claude-bb/settings.json"

# shellcheck source=/dev/null
source "${HOOK_SRC_DIR}/adapters/claude.sh"   # for ADAPTER_MATCHER

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
# Preserve an existing provider registry across reinstalls (Phase 3 rewrites
# this deliberately; a plain reinstall must not silently enable everything).
if [ -n "${HOOKLINE_PROVIDERS:-}" ]; then
  printf 'HOOKLINE_PROVIDERS="%s"\n' "$HOOKLINE_PROVIDERS" >> "$CONFIG_FILE"
fi
chmod 600 "$CONFIG_FILE"
echo "Config written to $CONFIG_FILE"

# Install hook (entry + core + adapters)
cp -R "${HOOK_SRC_DIR}/." "$(dirname "$HOOK_DST")/"
chmod +x "$HOOK_DST"
echo "Hook installed to $(dirname "$HOOK_DST")"

# Install CLI. Fall back to ~/.local/bin when /usr/local/bin isn't writable —
# the launchd plist execs this path, so a silent copy failure means the daemon
# exits 78 in a KeepAlive loop while install still reports success.
CLI_SRC="${REPO}/hookline"
CLI_DST="/usr/local/bin/hookline"
if [ -f "$CLI_SRC" ]; then
  if cp "$CLI_SRC" "$CLI_DST" 2>/dev/null && chmod +x "$CLI_DST"; then
    echo "CLI installed to $CLI_DST"
  else
    CLI_DST="${HOME}/.local/bin/hookline"
    mkdir -p "$(dirname "$CLI_DST")"
    cp "$CLI_SRC" "$CLI_DST" && chmod +x "$CLI_DST"
    echo "CLI installed to $CLI_DST (/usr/local/bin not writable — symlink if you want the classic path)"
  fi
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

# Register the hook in a Claude-family settings file, keyed by provider. The
# command passes the provider id so HOOKLINE_PROVIDERS can enable/disable each
# registration independently; the `[ -x ]` guard keeps settings valid (and
# silent) when the hook is not installed.
register_provider() {
  local settings="$1" provider="$2"
  local hook_cmd="[ -x \"\$HOME/.local/share/hookline/hooks/hookline.sh\" ] && \"\$HOME/.local/share/hookline/hooks/hookline.sh\" ${provider} || true"
  [ -f "$settings" ] || return 1

  if jq -e --arg cmd "$hook_cmd" '.hooks.PreToolUse[]?.hooks[]? | select(.command? == $cmd)' "$settings" &>/dev/null; then
    echo "Hook already registered in $settings (provider: $provider)"
  elif jq -e '.hooks.PreToolUse[]? | select(.hooks[]?.command? | contains("hookline"))' "$settings" &>/dev/null; then
    # Upgrade a pre-registry registration to the provider-aware command form.
    jq --arg cmd "$hook_cmd" --arg matcher "$ADAPTER_MATCHER" '
      .hooks.PreToolUse |= map(
        if ([.hooks[]?.command // ""] | any(contains("hookline")))
        then (.matcher = $matcher |
              .hooks |= map(if ((.command // "") | contains("hookline")) then .command = $cmd else . end))
        else . end)
    ' "$settings" > "${settings}.tmp" || return 1
    mv "${settings}.tmp" "$settings" || return 1
    echo "Hook registration upgraded in $settings (provider: $provider)"
  else
    jq --arg cmd "$hook_cmd" --arg matcher "$ADAPTER_MATCHER" '
      .hooks //= {} |
      .hooks.PreToolUse //= [] |
      .hooks.PreToolUse += [{
        "matcher": $matcher,
        "hooks": [{"type": "command", "command": $cmd, "timeout": 310}]
      }]
    ' "$settings" > "${settings}.tmp" || return 1
    mv "${settings}.tmp" "$settings" || return 1
    echo "Hook registered in $settings (provider: $provider)"
  fi
}

if register_provider "$SETTINGS" "claude"; then
  :
else
  echo "Warning: $SETTINGS not found — register the hook manually."
  echo "Add to ~/.claude/settings.json:"
  # shellcheck disable=SC2016  # literal $HOME is intentional — expands at hook runtime
  echo '  "hooks": {"PreToolUse": [{"matcher": "'"$ADAPTER_MATCHER"'", "hooks": [{"type": "command", "command": "[ -x \"\$HOME/.local/share/hookline/hooks/hookline.sh\" ] && \"\$HOME/.local/share/hookline/hooks/hookline.sh\" claude || true", "timeout": 310}]}]}'
fi

# blackbox = same claude adapter, own settings file; skip silently if the
# blackbox Claude config isn't present on this machine.
if [ -f "$SETTINGS_BB" ]; then
  register_provider "$SETTINGS_BB" "blackbox"
fi

echo
echo "=== Installation complete ==="
echo "Subscribe to topic '${HOOKLINE_TOPIC}' in the ntfy app on your phone."
echo "Run 'hookline status' to verify everything is running."
echo "Run 'bash scripts/test.sh' to send a test notification."
