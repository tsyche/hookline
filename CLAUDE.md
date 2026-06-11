# hookline — AI assistant context

Approve Claude Code permission prompts from your phone via ntfy.sh. A `PreToolUse`
hook shows the terminal prompt instantly; if you walk away, a background daemon
sends a phone notification and routes your response back to dismiss the prompt.

See [README.md](README.md) for full usage and [ROADMAP.md](ROADMAP.md) for planned work.

## Stack

- **Hook** (`hooks/hookline.sh`) — Bash. Fires on `PreToolUse`, handles grace period,
  safe-prefix allowlist, and keystroke injection for AppleScript terminals.
- **Daemon** (`daemon/hookline-daemon`) — Python (stdlib only). Persistent SSE
  connection to ntfy for instant phone responses; injects into tmux via `tmux send-keys`.
  Managed by launchd (`daemon/com.hookline.daemon.plist`).
- **CLI** (`hookline`) — Bash. `status`, `topic`, `daemon start/stop/restart/status`.
- **Install/uninstall** (`install.sh`, `uninstall.sh`), **test** (`scripts/test.sh`).

## Key commands

```bash
just install        # install hook, daemon, CLI, launchd registration
just test           # send a test notification
just status         # config, daemon status, connectivity, recent log
just lint           # shellcheck the shell scripts + py_compile the daemon
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

- Config: `~/.config/hookline/config` (not tracked)
- Installed runtime: `~/.local/share/hookline/` (hook, daemon, socket, logs)
- Hook registration: `~/.claude/settings.json`
