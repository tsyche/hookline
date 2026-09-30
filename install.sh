#!/bin/bash
set -e

REPO="$(cd "$(dirname "$0")" && pwd)"
HOOK_SRC_DIR="${REPO}/hooks"
HOOK_DST="${HOME}/.local/share/hookline/hooks/hookline.sh"
DAEMON_SRC="${REPO}/daemon/hookline-daemon"
DAEMON_DST="${HOME}/.local/share/hookline/daemon/hookline-daemon"
WATCHDOG_SRC="${REPO}/daemon/watchdog.py"
WATCHDOG_DST="${HOME}/.local/share/hookline/watchdog.py"
CONFIG_DIR="${HOME}/.config/hookline"
CONFIG_FILE="${CONFIG_DIR}/config"
LOG_DIR="${HOME}/.local/share/hookline"
SETTINGS="${HOME}/.claude/settings.json"
SETTINGS_BB="${HOME}/.claude-bb/settings.json"

# shellcheck source=/dev/null
source "${HOOK_SRC_DIR}/adapters/claude.sh"   # for ADAPTER_MATCHER

# Init system: launchd (macOS) or systemd --user (Linux). HOOKLINE_INIT_SYSTEM
# overrides auto-detection so tests are deterministic on macOS and Linux CI.
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

# Fail fast on an unsupported platform before writing anything — without
# launchd or systemd there is nowhere to register the daemon, and keystroke
# injection needs macOS osascript. HOOKLINE_SANDBOX=1 falls back to the
# launchd layout (registration is skipped in sandbox mode anyway).
if [[ "$INIT_SYSTEM" == "none" ]]; then
  if [[ "${HOOKLINE_SANDBOX:-0}" == "1" ]]; then
    INIT_SYSTEM="launchd"
  else
    echo "Error: hookline supports macOS or Linux with systemd." >&2
    echo "Nothing was installed." >&2
    exit 1
  fi
fi

# Job files: a plist pair under ~/Library/LaunchAgents on launchd, unit files
# under ~/.config/systemd/user on systemd.
if [[ "$INIT_SYSTEM" == "systemd" ]]; then
  JOB_DIR="${HOME}/.config/systemd/user"
  DAEMON_JOB_SRC="${REPO}/daemon/hookline-daemon.service"
  DAEMON_JOB_DST="${JOB_DIR}/hookline-daemon.service"
  DAEMON_JOB_LABEL="hookline-daemon.service"
  WATCHDOG_JOB_SRC="${REPO}/daemon/hookline-watchdog.service"
  WATCHDOG_JOB_DST="${JOB_DIR}/hookline-watchdog.service"
  TIMER_JOB_SRC="${REPO}/daemon/hookline-watchdog.timer"
  TIMER_JOB_DST="${JOB_DIR}/hookline-watchdog.timer"
  TIMER_JOB_LABEL="hookline-watchdog.timer"
else
  JOB_DIR="${HOME}/Library/LaunchAgents"
  DAEMON_JOB_SRC="${REPO}/daemon/com.hookline.daemon.plist"
  DAEMON_JOB_DST="${JOB_DIR}/com.hookline.daemon.plist"
  DAEMON_JOB_LABEL="com.hookline.daemon"
  WATCHDOG_JOB_SRC="${REPO}/daemon/com.hookline.watchdog.plist"
  WATCHDOG_JOB_DST="${JOB_DIR}/com.hookline.watchdog.plist"
  TIMER_JOB_SRC=""
  TIMER_JOB_DST=""
  TIMER_JOB_LABEL=""
fi

# systemd: probe the user instance before writing anything — a missing
# linger / user bus is the top fresh-Linux failure, and install would
# otherwise die halfway through registration.
if [[ "$INIT_SYSTEM" == "systemd" ]] && [[ "${HOOKLINE_SANDBOX:-0}" != "1" ]]; then
  if ! systemctl --user daemon-reload >/dev/null 2>&1; then
    echo "Error: systemd --user is not reachable for $(id -un)." >&2
    echo "Run: loginctl enable-linger $(id -un)  (then log out and back in) and retry." >&2
    echo "Nothing was installed." >&2
    exit 1
  fi
fi

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
mkdir -p "$(dirname "$HOOK_DST")" "$(dirname "$DAEMON_DST")" "$CONFIG_DIR" "$LOG_DIR" "$JOB_DIR"

# Configure topic
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

if [ -z "$HOOKLINE_TOPIC" ]; then
  echo -n "Enter ntfy topic name (leave blank to generate): "
  # EOF (piped install, no tty) → empty topic → generate one below; without
  # `|| true` set -e would abort here.
  read -r topic || true
  if [ -z "$topic" ]; then
    topic="hookline-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 12)"
    echo "Generated topic: $topic"
  fi
  HOOKLINE_TOPIC="$topic"
fi

# Write config. Reinstaller preserves existing values (topic, self-hosted
# server/auth, extended window) — only fills defaults for what's unset.
cat > "$CONFIG_FILE" <<EOF
HOOKLINE_TOPIC="${HOOKLINE_TOPIC}"
HOOKLINE_NTFY_SERVER="${HOOKLINE_NTFY_SERVER:-https://ntfy.sh}"
HOOKLINE_GRACE_PERIOD="${HOOKLINE_GRACE_PERIOD:-20}"
HOOKLINE_PHONE_TIMEOUT="${HOOKLINE_PHONE_TIMEOUT:-900}"
EOF
if [ -n "${HOOKLINE_NTFY_USERNAME:-}" ]; then
  printf 'HOOKLINE_NTFY_USERNAME="%s"\n' "$HOOKLINE_NTFY_USERNAME" >> "$CONFIG_FILE"
fi
if [ -n "${HOOKLINE_NTFY_PASSWORD:-}" ]; then
  printf 'HOOKLINE_NTFY_PASSWORD="%s"\n' "$HOOKLINE_NTFY_PASSWORD" >> "$CONFIG_FILE"
fi
if [ -n "${HOOKLINE_EXTENDED_WAIT:-}" ]; then
  printf 'HOOKLINE_EXTENDED_WAIT=%s\n' "$HOOKLINE_EXTENDED_WAIT" >> "$CONFIG_FILE"
fi
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

# Register with opencode by dropping the plugin into its auto-loaded global
# plugin directory — no opencode.jsonc edit, so the agentrc-managed config is
# never touched. Skipped when opencode itself isn't present on this machine.
OPC_PLUGIN_DST="${HOME}/.config/opencode/plugins/hookline.js"
if [ -d "${HOME}/.config/opencode" ]; then
  mkdir -p "$(dirname "$OPC_PLUGIN_DST")"
  cp "${HOOK_SRC_DIR}/plugins/hookline.js" "$OPC_PLUGIN_DST"
  echo "OpenCode plugin installed to $OPC_PLUGIN_DST"
fi

# Install CLI. Fall back to ~/.local/bin when /usr/local/bin isn't writable —
# the daemon job (plist/unit) execs this path, so a silent copy failure means
# the daemon exits 78 in a KeepAlive loop while install still reports success.
# HOOKLINE_CLI_DIR overrides the destination (tests use it to exercise
# non-sandbox registration without touching the real /usr/local/bin);
# HOOKLINE_SANDBOX=1 (scripts/install-test.sh) forces the home-local path so
# test runs never touch /usr/local/bin.
CLI_SRC="${REPO}/hookline"
CLI_DST="/usr/local/bin/hookline"
if [ -f "$CLI_SRC" ]; then
  if [ -n "${HOOKLINE_CLI_DIR:-}" ]; then
    CLI_DST="$HOOKLINE_CLI_DIR"
    mkdir -p "$(dirname "$CLI_DST")"
    cp "$CLI_SRC" "$CLI_DST" && chmod +x "$CLI_DST"
    echo "CLI installed to $CLI_DST (HOOKLINE_CLI_DIR)"
  elif [ "${HOOKLINE_SANDBOX:-0}" = "1" ]; then
    CLI_DST="${HOME}/.local/bin/hookline"
    mkdir -p "$(dirname "$CLI_DST")"
    cp "$CLI_SRC" "$CLI_DST" && chmod +x "$CLI_DST"
    echo "CLI installed to $CLI_DST (sandbox mode — /usr/local/bin untouched)"
  elif cp "$CLI_SRC" "$CLI_DST" 2>/dev/null && chmod +x "$CLI_DST"; then
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

# Record the installed version — `hookline status` compares it against the
# latest GitHub release to flag upgrades.
if [ -f "${REPO}/VERSION" ]; then
  cp "${REPO}/VERSION" "${LOG_DIR}/VERSION"
fi

# Install and register the daemon job (launchd plist / systemd unit)
sed -e "s|HOOKLINE_DAEMON_PATH|$CLI_DST|g" \
    -e "s|HOOKLINE_LOG_DIR|$LOG_DIR|g" \
    "$DAEMON_JOB_SRC" > "$DAEMON_JOB_DST"
if [ "${HOOKLINE_SANDBOX:-0}" = "1" ]; then
  echo "Daemon job written to $DAEMON_JOB_DST ($INIT_SYSTEM registration skipped — HOOKLINE_SANDBOX=1)"
elif [ "$INIT_SYSTEM" = "systemd" ]; then
  systemctl --user daemon-reload
  systemctl --user enable --now "$DAEMON_JOB_LABEL"
  echo "Daemon registered with systemd and started"
else
  launchctl unload "$DAEMON_JOB_DST" 2>/dev/null || true
  launchctl load "$DAEMON_JOB_DST"
  echo "Daemon registered with launchd and started"
fi

# Install the heartbeat watchdog — a StartInterval job (launchd) / 60s timer
# (systemd) that restarts a hung daemon (KeepAlive only catches processes that
# actually exit).
cp "$WATCHDOG_SRC" "$WATCHDOG_DST"
chmod +x "$WATCHDOG_DST"
sed -e "s|HOOKLINE_WATCHDOG_PATH|$WATCHDOG_DST|g" \
    -e "s|HOOKLINE_LOG_DIR|$LOG_DIR|g" \
    "$WATCHDOG_JOB_SRC" > "$WATCHDOG_JOB_DST"
if [ "$INIT_SYSTEM" = "systemd" ]; then
  sed -e "s|HOOKLINE_LOG_DIR|$LOG_DIR|g" "$TIMER_JOB_SRC" > "$TIMER_JOB_DST"
fi
if [ "${HOOKLINE_SANDBOX:-0}" = "1" ]; then
  echo "Watchdog job written to $WATCHDOG_JOB_DST ($INIT_SYSTEM registration skipped — HOOKLINE_SANDBOX=1)"
elif [ "$INIT_SYSTEM" = "systemd" ]; then
  systemctl --user daemon-reload
  systemctl --user enable --now "$TIMER_JOB_LABEL"
  echo "Heartbeat watchdog registered with systemd"
else
  launchctl unload "$WATCHDOG_JOB_DST" 2>/dev/null || true
  launchctl load "$WATCHDOG_JOB_DST"
  echo "Heartbeat watchdog registered with launchd"
fi

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

# codex: merge a PermissionRequest entry into ~/.codex/hooks.json — codex has
# no settings-JSON surface, and this file is separate from config.toml, so the
# user's codex config is never touched. Skipped when codex itself isn't present.
# The hook still no-ops until `codex` is added to HOOKLINE_PROVIDERS. Merging
# preserves any hooks already in the file; a fresh file starts from {"hooks":{}}.
CODEX_DIR="${HOME}/.codex"
CODEX_HOOKS="${CODEX_DIR}/hooks.json"
if [ -d "$CODEX_DIR" ]; then
  # shellcheck source=/dev/null
  source "${HOOK_SRC_DIR}/adapters/codex.sh"   # for ADAPTER_MATCHER (codex registration is last)
  if [ ! -s "$CODEX_HOOKS" ]; then
    printf '%s\n' '{"hooks":{}}' > "$CODEX_HOOKS"
  fi
  hook_cmd="[ -x \"\$HOME/.local/share/hookline/hooks/hookline.sh\" ] && \"\$HOME/.local/share/hookline/hooks/hookline.sh\" codex || true"
  if jq -e --arg cmd "$hook_cmd" '.hooks.PermissionRequest[]?.hooks[]? | select(.command? == $cmd)' "$CODEX_HOOKS" &>/dev/null; then
    echo "Hook already registered in $CODEX_HOOKS (provider: codex)"
  else
    jq --arg cmd "$hook_cmd" --arg matcher "$ADAPTER_MATCHER" '
      .hooks //= {} |
      .hooks.PermissionRequest = ((.hooks.PermissionRequest // []) +
        [{matcher: $matcher, hooks: [{type: "command", command: $cmd, timeout: 30}]}])
    ' "$CODEX_HOOKS" > "${CODEX_HOOKS}.tmp" && mv "${CODEX_HOOKS}.tmp" "$CODEX_HOOKS"
    echo "Hook registered in $CODEX_HOOKS (provider: codex)"
    echo "Review it once inside codex (/hooks) — codex skips untrusted hooks until then."
  fi
fi

# systemd: without linger the user manager (and the daemon with it) stops at
# logout — flag it, never fail the install over it.
if [[ "$INIT_SYSTEM" == "systemd" ]] && [[ "${HOOKLINE_SANDBOX:-0}" != "1" ]] \
   && command -v loginctl >/dev/null 2>&1 \
   && [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)" != "yes" ]; then
  echo "Note: user services stop at logout — enable linger to keep hookline alive:"
  echo "  loginctl enable-linger $(id -un)"
fi

echo
echo "=== Installation complete ==="
echo "Subscribe to topic '${HOOKLINE_TOPIC}' in the ntfy app on your phone."
echo "Run 'hookline status' to verify everything is running."
echo "Run 'hookline doctor' if notifications ever stop arriving."
echo "Run 'bash scripts/test.sh' to send a test notification."
