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
