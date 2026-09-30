# hookline — AI assistant context

Approve Claude Code permission prompts from your phone via ntfy.sh. A `PreToolUse`
hook shows the terminal prompt instantly; if you walk away, a background daemon
sends a phone notification and routes your response back to dismiss the prompt.

See [README.md](README.md) for full usage and [ROADMAP.md](ROADMAP.md) for planned work.

## Stack

- **Hook** (`hooks/hookline.sh` entry → `hooks/core.sh` + a provider adapter in `hooks/adapters/`) —
  Bash. Entry resolves the provider (`hookline.sh [provider]`, default `claude`, the local
  custom provider rides the claude adapter), gates on `HOOKLINE_PROVIDERS`, then core runs grace period,
  safe-prefix allowlist, and daemon handoff; the adapter translates payload, decision JSON,
  allowlist source, progress signal, and keystroke injection.
- **opencode plugin** (`hooks/plugins/hookline.js` → `~/.config/opencode/plugins/hookline.js`) —
  Node. Sees `permission.asked` and `question.asked`/`question.v2.asked`, spawns
  `hookline.sh opencode` with the payload on stdin, and answers the native prompt or question
  dialog through a unix-socket bridge (opencode's serverUrl does not accept plain TCP; only the
  in-process SDK client can reply — permissions via `postSessionIdPermissionsPermissionId`,
  questions via `client.question.reply`/`reject`). Appends a local-answer line on
  `permission.replied` and `question.replied`/`question.rejected` for the away-detection signal.
- **codex adapter** (`hooks/adapters/codex.sh`) — Bash. Interim Flow A hack over codex's
  `PermissionRequest` event: empty stdout declines, so codex's own approval menu shows; the
  background watcher injects Enter (approve, option 1 preselected) / Esc (cancel) — into the
  hook's own `$TMUX_PANE` via `tmux send-keys` when inside tmux (pane-exact, works detached;
  same pattern as claude's tmux path, watcher-side because the daemon's keys are
  claude-hardcoded), frontmost-app osascript otherwise (claude's bare-terminal path).
  Response-only (`ADAPTER_RESPONSE_ONLY=1`); local-answer signal = session rollout JSONL
  growth. Registered by merging `~/.codex/hooks.json` (foreign hooks preserved; one-time
  `/hooks` trust review).
- **grok adapter** (`hooks/adapters/grok.sh`) — Bash. Rides grok's claude-compatible
  `PreToolUse` hooks: `install.sh` merges a `hookline.json` entry into `~/.grok/hooks/`
  (global hooks are always trusted; foreign hooks preserved); `ask` forces grok's own
  permission card, safe prefixes and the Claude-settings allowlist defer, questions defer
  into grok's picker (claude-shaped payload — shared question builder). Response-only
  (`ADAPTER_RESPONSE_ONLY=1`) because the daemon's tmux keys are claude-specific ("1" would
  be grok's always-approve row) — the watcher injects: allow = the allow-once row's digit
  parsed off the pane screenshot (labels/order vary by prompt class; Enter is never safe;
  parse miss = no injection), deny = Ctrl+C (Esc parks focus), question answer = option
  digit (auto-advances, auto-submits); outside tmux the screenshot is iTerm2 session
  contents. Matcher = anchored grok-native names (`run_terminal_command`|`write`|
  `search_replace`|`ask_user_question` + claude aliases). Local-answer signal = raw
  `updates.jsonl` line count.
- **Daemon** (`daemon/hookline-daemon`) — Python (stdlib only), managed by launchd
  (`daemon/com.hookline.daemon.plist`) or, on Linux, systemd user units
  (`daemon/hookline-daemon.service` + `daemon/hookline-watchdog.service` +
  `daemon/hookline-watchdog.timer`, written to
  `~/.config/systemd/user/`; `HOOKLINE_INIT_SYSTEM=launchd|systemd|none` overrides
  auto-detection for tests). Listens on a Unix socket
  (`~/.local/share/hookline/daemon.sock`) for messages from hook invocations; holds a
  persistent SSE connection to the ntfy response topic so phone responses arrive instantly;
  keeps a session registry mapping `session_id → {tty, term_program, tmux_pane}`. On
  response, tmux sessions are injected via `tmux send-keys` directly, everything else gets a
  response file that the hook process (a child of the terminal) reads — injection stays in
  the process tree that already has macOS Accessibility trust. Falls back to inline polling
  when the daemon is unavailable. Touches `heartbeat` (serve loop) and `sse-heartbeat`
  (SSE connect/receive, bounded by a 300s read timeout); `daemon/watchdog.py` is a
  launchd `StartInterval` / systemd 60s timer job that restarts the daemon when either
  goes stale — KeepAlive/Restart only catches processes that exit; it checks the
  platform's loaded/enabled state so a deliberately stopped daemon is never restarted.
- **CLI** (`hookline`) — Bash. `setup`, `status`, `doctor`, `topic`, `daemon start/stop/restart/status`.
- **Install/uninstall** (`install.sh`, `uninstall.sh`), **tests** (`scripts/test.sh`,
  `scripts/hook-golden.sh` — sandboxed stdout contract tests, no network;
  `tests/test_daemon.py` — daemon unit tests; `tests/test_plugin.mjs` — opencode plugin
  unit tests; `scripts/doctor-test.sh` — sandboxed doctor report tests;
  `scripts/status-test.sh` — sandboxed status report tests;
  `scripts/patterns-test.sh` — sandboxed pattern-CLI tests;
  `scripts/install-test.sh` — sandboxed install/uninstall round-trip tests;
  `scripts/get-test.sh` — sandboxed get.sh one-line install tests (file:// tarball, no network);
  `scripts/focus-test.sh` — sandboxed bare-terminal focus-targeting tests (dry-run, no osascript);
  `scripts/release-smoke-test.sh` — sandboxed release smoke check tests).
  Install/uninstall honor `HOOKLINE_SANDBOX=1` (no launchctl/systemctl, no `/usr/local/bin`)
  and pin the platform via `HOOKLINE_INIT_SYSTEM`; `HOOKLINE_CLI_DIR` redirects the CLI
  install so non-sandbox registration tests never touch `/usr/local/bin`.
  `just check-gates` runs every gate CI runs (`ci.yml` calls it — keep both in sync
  via the recipe, never by listing steps twice).

## Key commands

```bash
just install        # install hook, daemon, CLI, launchd/systemd registration
just test           # send a test notification
just check-gates    # every gate CI runs, in one command (single source of truth)
just golden         # hook stdout contract tests (sandboxed, no network)
just test-daemon    # daemon unit tests (registry, routing, heartbeat, watchdog)
just test-plugin    # opencode plugin unit tests (node --test, fake SDK client)
just doctor-test    # sandboxed `hookline doctor` report tests (no network, no init system)
just status-test    # sandboxed `hookline status` report tests (no network, no init system)
just patterns-test  # sandboxed pattern-CLI tests (`patterns`/`remove-pattern`/`clear-patterns`)
just hooks          # enable in-repo .githooks (pre-commit check-docs, pre-push check-gates)
just install-test   # sandboxed install/uninstall round-trip tests (no launchd/systemd)
just get-test       # sandboxed get.sh one-line install tests (fake HOME, no network, no init system)
just focus-test     # sandboxed bare-terminal focus-targeting tests (dry-run, no osascript)
just release-smoke-test # sandboxed release smoke check tests (fake gh, no network)
just status         # config, daemon status, connectivity, recent log
just lint           # shellcheck the shell scripts + py_compile the Python files
just logs           # tail hook + daemon logs
just uninstall      # remove everything
```

## Conventions that bit us (don't regress)

- **Always use absolute `/usr/bin/python3`** in the hook and CLI, never bare `python3` —
  asdf shims error when no version is selected and silently break the daemon handoff.
- **The daemon runs under launchd / the systemd user manager with a minimal PATH**
  (no `/usr/local/bin`) — resolve absolute paths for external binaries like `tmux`, or
  injection throws `FileNotFoundError`.
- **Deny injects Escape, not `3`** — permission menus vary in option count; `3` only
  works on 3-option menus. Escape cancels regardless.
- **Notification title is `[tmux-session / project]`** inside tmux — the project basename
  alone can be stale (`--resume`) and collide with tmux session names.

## Config & data

- Config: `~/.config/hookline/config` (not tracked) — `HOOKLINE_PROVIDERS` names the enabled
  providers (concrete local ids live only in this untracked file); unset = all enabled;
  `hookline.sh <provider>` is what the settings entry passes
- Installed runtime: `~/.local/share/hookline/` (hooks dir = entry + core + adapters,
  daemon, socket, logs)
- Hook registration: `~/.claude/settings.json` (provider `claude`) and
  `~/.claude-bb/settings.json` (the local custom claude-profile provider); each registration
  is an inverse pair with install/uninstall. opencode registers differently — plugin file
  copied to `~/.config/opencode/plugins/hookline.js` (no settings-JSON entry); codex likewise —
  `PermissionRequest` entry merged into `~/.codex/hooks.json` (no config.toml edits)
