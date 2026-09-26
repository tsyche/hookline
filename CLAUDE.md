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
  Node. Sees `permission.asked`, spawns `hookline.sh opencode` with the payload on stdin, and
  answers the native prompt through a unix-socket bridge (opencode's serverUrl does not accept
  plain TCP; only the in-process SDK client can reply). Appends a local-answer line on
  `permission.replied` for the away-detection signal.
- **Daemon** (`daemon/hookline-daemon`) — Python (stdlib only), managed by launchd
  (`daemon/com.hookline.daemon.plist`). Listens on a Unix socket
  (`~/.local/share/hookline/daemon.sock`) for messages from hook invocations; holds a
  persistent SSE connection to the ntfy response topic so phone responses arrive instantly;
  keeps a session registry mapping `session_id → {tty, term_program, tmux_pane}`. On
  response, tmux sessions are injected via `tmux send-keys` directly, everything else gets a
  response file that the hook process (a child of the terminal) reads — injection stays in
  the process tree that already has macOS Accessibility trust. Falls back to inline polling
  when the daemon is unavailable. Touches `heartbeat` (serve loop) and `sse-heartbeat`
  (SSE connect/receive, bounded by a 300s read timeout); `daemon/watchdog.py` is a
  launchd `StartInterval` job that restarts the daemon when either goes stale — KeepAlive
  only catches processes that exit.
- **CLI** (`hookline`) — Bash. `status`, `doctor`, `topic`, `daemon start/stop/restart/status`.
- **Install/uninstall** (`install.sh`, `uninstall.sh`), **tests** (`scripts/test.sh`,
  `scripts/hook-golden.sh` — sandboxed stdout contract tests, no network;
  `tests/test_daemon.py` — daemon unit tests; `scripts/doctor-test.sh` — sandboxed
  doctor report tests).

## Key commands

```bash
just install        # install hook, daemon, CLI, launchd registration
just test           # send a test notification
just golden         # hook stdout contract tests (sandboxed, no network)
just test-daemon    # daemon unit tests (registry, routing, heartbeat, watchdog)
just doctor-test    # sandboxed `hookline doctor` report tests (no network, no launchd)
just status         # config, daemon status, connectivity, recent log
just lint           # shellcheck the shell scripts + py_compile the Python files
just logs           # tail hook + daemon logs
just uninstall      # remove everything
```

## Conventions that bit us (don't regress)

- **Always use absolute `/usr/bin/python3`** in the hook and CLI, never bare `python3` —
  asdf shims error when no version is selected and silently break the daemon handoff.
- **The daemon runs under launchd with a minimal PATH** (no `/usr/local/bin`) — resolve
  absolute paths for external binaries like `tmux`, or injection throws `FileNotFoundError`.
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
  copied to `~/.config/opencode/plugins/hookline.js` (no settings-JSON entry)
