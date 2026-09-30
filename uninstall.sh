#!/bin/bash
set -e

HOOK_DIR_DST="${HOME}/.local/share/hookline/hooks"
SETTINGS="${HOME}/.claude/settings.json"
SETTINGS_BB="${HOME}/.claude-bb/settings.json"

# Init system (same detection as install.sh): HOOKLINE_INIT_SYSTEM overrides,
# else OSTYPE auto-detect. Only gates system calls — file removal below is
# file-driven, so a mismatch (e.g. INIT=none) still cleans up.
detect_init_system() {
  case "${HOOKLINE_INIT_SYSTEM:-}" in
    launchd|systemd|none) printf '%s' "${HOOKLINE_INIT_SYSTEM}"; return 0 ;;
  esac
  case "${OSTYPE:-}" in
    darwin*) printf 'launchd' ;;
    linux*)  if command -v systemctl >/dev/null 2>&1; then printf 'systemd'; else printf 'none'; fi ;;
    *)       printf 'none' ;;
  esac
}
INIT_SYSTEM="$(detect_init_system)"

DAEMON_PLIST="${HOME}/Library/LaunchAgents/com.hookline.daemon.plist"
WATCHDOG_PLIST="${HOME}/Library/LaunchAgents/com.hookline.watchdog.plist"
DAEMON_UNIT="${HOME}/.config/systemd/user/hookline-daemon.service"
WATCHDOG_UNIT="${HOME}/.config/systemd/user/hookline-watchdog.service"
WATCHDOG_TIMER="${HOME}/.config/systemd/user/hookline-watchdog.timer"

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

# Stop the daemon jobs before removing files (launchd KeepAlive / systemd
# Restart would respawn a daemon whose files are about to disappear).
# HOOKLINE_SANDBOX=1 (scripts/install-test.sh) skips the system call entirely.
if [ "${HOOKLINE_SANDBOX:-0}" != "1" ]; then
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    [ ! -f "$DAEMON_UNIT" ] || systemctl --user disable --now hookline-daemon.service 2>/dev/null || true
    [ ! -f "$WATCHDOG_TIMER" ] || systemctl --user disable --now hookline-watchdog.timer 2>/dev/null || true
  else
    [ ! -f "$DAEMON_PLIST" ] || { launchctl unload "$DAEMON_PLIST" 2>/dev/null || true; }
    [ ! -f "$WATCHDOG_PLIST" ] || { launchctl unload "$WATCHDOG_PLIST" 2>/dev/null || true; }
  fi
fi

# Remove the daemon job (file-driven inverse of install.sh — removes whatever
# the installed platform wrote)
if [ -f "$DAEMON_PLIST" ]; then
  rm -f "$DAEMON_PLIST"
  echo "Removed daemon launchd job"
fi
if [ -f "$DAEMON_UNIT" ]; then
  rm -f "$DAEMON_UNIT"
  echo "Removed daemon systemd unit"
fi

# Remove the heartbeat watchdog (plist / service+timer pair)
if [ -f "$WATCHDOG_PLIST" ]; then
  rm -f "$WATCHDOG_PLIST"
  echo "Removed watchdog launchd job"
fi
if [ -f "$WATCHDOG_UNIT" ] || [ -f "$WATCHDOG_TIMER" ]; then
  rm -f "$WATCHDOG_UNIT" "$WATCHDOG_TIMER"
  echo "Removed watchdog systemd units"
fi
if [ "$INIT_SYSTEM" = "systemd" ] && [ "${HOOKLINE_SANDBOX:-0}" != "1" ]; then
  systemctl --user daemon-reload 2>/dev/null || true
fi
rm -f "${HOME}/.local/share/hookline/watchdog.py"
rm -f "${HOME}/.local/share/hookline/VERSION"

# Remove the CLI (HOOKLINE_CLI_DIR is authoritative when set; sandbox mode
# never touches /usr/local/bin)
if [ -n "${HOOKLINE_CLI_DIR:-}" ] && [ -f "$HOOKLINE_CLI_DIR" ]; then
  rm -f "$HOOKLINE_CLI_DIR"
  echo "Removed $HOOKLINE_CLI_DIR"
elif [ "${HOOKLINE_SANDBOX:-0}" != "1" ] && { [ -f /usr/local/bin/hookline ] || [ -L /usr/local/bin/hookline ]; }; then
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

# Remove the codex registration (inverse of install.sh's merge — only the
# hookline PermissionRequest entries; every other hook in the file survives).
CODEX_HOOKS="${HOME}/.codex/hooks.json"
if [ -f "$CODEX_HOOKS" ] && \
   jq -e '.hooks.PermissionRequest[]?.hooks[]? | select((.command // "") | contains("hookline"))' "$CODEX_HOOKS" &>/dev/null; then
  jq '.hooks //= {} |
      .hooks.PermissionRequest = ((.hooks.PermissionRequest // []) |
        map(select([.hooks[]?.command // ""] | any(contains("hookline")) | not))) |
      if (.hooks.PermissionRequest | length) == 0 then del(.hooks.PermissionRequest) else . end' \
    "$CODEX_HOOKS" > "${CODEX_HOOKS}.tmp" && mv "${CODEX_HOOKS}.tmp" "$CODEX_HOOKS"
  echo "Hook removed from $CODEX_HOOKS"
fi

# Remove the grok registration (inverse of install.sh's merge — only the
# hookline PreToolUse entries; every other hook in the file survives).
GROK_HOOKS="${HOME}/.grok/hooks/hookline.json"
if [ -f "$GROK_HOOKS" ] && \
   jq -e '.hooks.PreToolUse[]?.hooks[]? | select((.command // "") | contains("hookline"))' "$GROK_HOOKS" &>/dev/null; then
  jq '.hooks //= {} |
      .hooks.PreToolUse = ((.hooks.PreToolUse // []) |
        map(select([.hooks[]?.command // ""] | any(contains("hookline")) | not))) |
      if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end' \
    "$GROK_HOOKS" > "${GROK_HOOKS}.tmp" && mv "${GROK_HOOKS}.tmp" "$GROK_HOOKS"
  echo "Hook removed from $GROK_HOOKS"
fi

# Optionally remove config
echo -n "Remove config and logs at ~/.config/hookline and ~/.local/share/hookline? [y/N] "
read -r confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
  rm -rf "${HOME}/.config/hookline" "${HOME}/.local/share/hookline"
  echo "Config and logs removed."
fi

echo "=== Uninstall complete ==="
