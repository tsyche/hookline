#!/bin/bash
set -e

HOOK_DST="${HOME}/.local/share/hookline/hooks/hookline.sh"
SETTINGS="${HOME}/.claude/settings.json"

echo "=== hookline uninstaller ==="

# Remove hook from Claude settings
if [ -f "$SETTINGS" ]; then
  jq 'del(.hooks.PreToolUse[]? | select(.hooks[]?.command? | contains("hookline")))' \
    "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
  echo "Hook removed from $SETTINGS"
fi

# Remove installed files
rm -f "$HOOK_DST"
echo "Removed $HOOK_DST"

# Optionally remove config
echo -n "Remove config and logs at ~/.config/hookline and ~/.local/share/hookline? [y/N] "
read -r confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
  rm -rf "${HOME}/.config/hookline" "${HOME}/.local/share/hookline"
  echo "Config and logs removed."
fi

echo "=== Uninstall complete ==="
