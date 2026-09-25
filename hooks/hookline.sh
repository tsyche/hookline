#!/bin/bash
# shellcheck disable=SC2034  # path globals consumed by sourced core.sh
# hookline — provider hook entry → ntfy.sh remote approval
# Usage: hookline.sh [provider]   (default provider: claude)
#
# Flow: config → HOOKLINE_PROVIDERS registry gate → source core + adapter →
# core_main. The core owns grace period / allowlist plumbing / daemon handoff /
# notification / retry; the adapter translates provider payload, decision JSON,
# allowlist source, progress signal, and injection profile.

PROVIDER="${1:-claude}"

CONFIG_FILE="${HOME}/.config/hookline/config"
LOG_FILE="${HOME}/.local/share/hookline/hookline.log"
DAEMON_SOCK="${HOME}/.local/share/hookline/daemon.sock"
DISABLED_FLAG="${HOME}/.config/hookline/disabled"
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=/dev/null
source "$CONFIG_FILE" 2>/dev/null || { echo "config not found"; exit 0; }

# Registry gate: a provider listed in HOOKLINE_PROVIDERS (or the list unset =
# all providers, for pre-registry configs) proceeds; anything else exits
# silently with no stdout so the provider applies its own default behavior.
if [ -n "${HOOKLINE_PROVIDERS:-}" ]; then
  case " $HOOKLINE_PROVIDERS " in
    *" $PROVIDER "*) ;;
    *) exit 0 ;;
  esac
fi

# Provider → adapter mapping. blackbox rides the claude adapter (separate
# settings file, same PreToolUse contract); future providers map to their own
# adapter file under adapters/.
case "$PROVIDER" in
  claude|blackbox) ADAPTER="claude" ;;
  *) ADAPTER="$PROVIDER" ;;
esac
[ -f "$HOOK_DIR/adapters/$ADAPTER.sh" ] || exit 0

# shellcheck source=/dev/null
source "$HOOK_DIR/core.sh"
# shellcheck source=/dev/null
source "$HOOK_DIR/adapters/$ADAPTER.sh"

core_main
