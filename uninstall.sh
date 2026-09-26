#!/bin/bash
set -e

HOOK_DIR_DST="${HOME}/.local/share/hookline/hooks"
SETTINGS="${HOME}/.claude/settings.json"
SETTINGS_BB="${HOME}/.claude-bb/settings.json"

echo "=== hookline uninstaller ==="

# Remove hook registrations from every Claude-family settings file (per-provider
# inverses of install.sh's register_provider — same contains("hookline") match).
for _settings in "$SETTINGS" "$SETTINGS_BB"; do
  [ -f "$_settings" ] || continue
  jq 'del(.hooks.PreToolUse[]? | select(.hooks[]?.command? | contains("hookline")))' \
    "$_settings" > "${_settings}.tmp" && mv "${_settings}.tmp" "$_settings"
  echo "Hook removed from $_settings"
done

# Remove installed files (entry + core + adapters)
rm -rf "$HOOK_DIR_DST"
echo "Removed $HOOK_DIR_DST"

# Remove the daemon launchd job (inverse of install.sh) — unload first so
# KeepAlive can't respawn a daemon whose files are about to disappear.
# HOOKLINE_SANDBOX=1 (scripts/install-test.sh) skips launchctl entirely.
DAEMON_PLIST="${HOME}/Library/LaunchAgents/com.hookline.daemon.plist"
if [ -f "$DAEMON_PLIST" ]; then
  if [ "${HOOKLINE_SANDBOX:-0}" != "1" ]; then
    launchctl unload "$DAEMON_PLIST" 2>/dev/null || true
  fi
  rm -f "$DAEMON_PLIST"
  echo "Removed daemon launchd job"
fi

# Remove the heartbeat watchdog (unload first so it can't restart a daemon
# that no longer exists)
WATCHDOG_PLIST="${HOME}/Library/LaunchAgents/com.hookline.watchdog.plist"
if [ -f "$WATCHDOG_PLIST" ]; then
  if [ "${HOOKLINE_SANDBOX:-0}" != "1" ]; then
    launchctl unload "$WATCHDOG_PLIST" 2>/dev/null || true
  fi
  rm -f "$WATCHDOG_PLIST"
  echo "Removed watchdog launchd job"
fi
rm -f "${HOME}/.local/share/hookline/watchdog.py"

# Remove the CLI (sandbox mode never touches /usr/local/bin)
if [ "${HOOKLINE_SANDBOX:-0}" != "1" ] && { [ -f /usr/local/bin/hookline ] || [ -L /usr/local/bin/hookline ]; }; then
  rm -f /usr/local/bin/hookline
  echo "Removed /usr/local/bin/hookline"
fi
if [ -f "${HOME}/.local/bin/hookline" ]; then
  rm -f "${HOME}/.local/bin/hookline"
  echo "Removed ${HOME}/.local/bin/hookline"
fi

# Remove the opencode plugin registration (opencode's own config is untouched)
OPC_PLUGIN="${HOME}/.config/opencode/plugins/hookline.js"
if [ -f "$OPC_PLUGIN" ]; then
  rm -f "$OPC_PLUGIN"
  echo "Removed $OPC_PLUGIN"
fi

# Optionally remove config
echo -n "Remove config and logs at ~/.config/hookline and ~/.local/share/hookline? [y/N] "
read -r confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
  rm -rf "${HOME}/.config/hookline" "${HOME}/.local/share/hookline"
  echo "Config and logs removed."
fi

echo "=== Uninstall complete ==="
