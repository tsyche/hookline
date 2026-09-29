# hookline

[![ci](https://github.com/tsyche/hookline/actions/workflows/ci.yml/badge.svg)](https://github.com/tsyche/hookline/actions/workflows/ci.yml)

**tl;dr:** Approve permission prompts from your phone via [ntfy.sh](https://ntfy.sh) — works with Claude Code, Codex, OpenCode, and any hook-compatible AI coding agent on macOS. A 20-second grace period keeps your phone quiet when you're at the terminal.

When an agent needs permission to run a tool, the terminal prompt appears instantly. If you answer at the terminal, your phone is never notified. If you walk away, a push notification arrives on your phone after the grace period — tap to respond, and the prompt auto-dismisses.

## How It Works

```
Agent fires hook (PreToolUse / PermissionRequest) or plugin event
  → Terminal prompt appears immediately
  → 20-second grace period starts
    ├── Answered at terminal? → phone stays quiet
    └── No answer? → ntfy.sh notification sent to phone
          → Tap Allow / Deny / Retry
            → Adapter resolves the prompt (keystroke injection or reply API)
```

Each provider plugs into a provider-neutral core through an adapter: Claude Code via its [hooks system](https://docs.anthropic.com/en/docs/claude-code/hooks) (`PreToolUse` event), Codex via its [hooks system](https://developers.openai.com/codex/hooks) (`PermissionRequest` event), OpenCode via an auto-loaded plugin, others the same way. A background daemon maintains a persistent SSE connection to ntfy so phone responses arrive instantly.

## Requirements

- macOS (Terminal.app, iTerm2, WezTerm, or tmux — see [terminal support](#terminal-support))
- `bash`, `jq`, `curl`, `python3`
- `just` (optional — `bash install.sh` works without it)
- [ntfy app](https://ntfy.sh) on your phone (iOS / Android)

## Install

```bash
git clone https://github.com/tsyche/hookline.git
cd hookline
just install          # or: bash install.sh
```

Run `just` in the repo to see every development command (`lint`, `golden`,
`check-docs`, `test`, …).

The installer will:

1. Check dependencies (`jq`, `curl`, `python3`)
2. Prompt for an ntfy topic name (or generate a random one)
3. Write config to `~/.config/hookline/config`
4. Install the hook to `~/.local/share/hookline/hooks/hookline.sh`
5. Install the daemon to `~/.local/share/hookline/daemon/hookline-daemon`
6. Register the daemon and the heartbeat watchdog with launchd (the watchdog
   restarts a hung daemon — `KeepAlive` only catches processes that exit)
7. Register the hook in `~/.claude/settings.json` (plus a second Claude-profile settings file when one is present on the machine)
8. Install the OpenCode plugin to `~/.config/opencode/plugins/hookline.js`, when `~/.config/opencode` exists
9. Merge the Codex `PermissionRequest` hook into `~/.codex/hooks.json`, when `~/.codex` exists (existing hooks in the file are preserved; review the new hook once inside codex via `/hooks` — codex skips untrusted hooks)

Then open the ntfy app and subscribe to your topic (and `your-topic-response`).

## Usage

Use your agent normally. When a permission prompt fires:

- **At your terminal** — answer as usual. No phone notification is sent.
- **Away from your terminal** — after 20 seconds, a push notification arrives on your phone.

### Phone notification buttons

| Button | Action |
|--------|--------|
| **Allow** | Approves this one request; terminal prompt auto-dismisses |
| **Deny** | Rejects the request; terminal prompt auto-dismisses with denial |
| **Retry** | Resends a fresh notification (useful when you catch it late) |

You can also type a reply in the ntfy channel instead of tapping: `allow`,
`deny`, or `retry` work anywhere a button would.

### Late replies (extended window)

After `HOOKLINE_PHONE_TIMEOUT` the phone gets a "Prompt expired" notice, but the
background watcher stays alive for another `HOOKLINE_EXTENDED_WAIT` seconds
(default 3600 = 1h; 0 disables). Anything sent inside that window still lands —
including a typed `retry` or a button tap on the earlier notification — and the
expiry notice says how long you have. When the window closes, the watcher gives
up and the prompt is terminal-only again.

### Question dialogs (OpenCode + Claude Code)

When OpenCode asks a question (`question.asked`) or Claude Code shows an
AskUserQuestion dialog, hookline applies the same grace period and notifies your
phone if you're away. For a single single-select question with 1–3 options, the
notification's buttons are the options themselves — tap one and the dialog
answers (OpenCode in-process via the reply bridge; Claude via keystroke
injection into the picker). You can also reply in the ntfy channel with an
option's number (`4`) or letter (`D`) — any option count works, since typing
goes past ntfy's 3-button cap; the body lists every option and ends with the
valid replies. Reply `retry` to re-notify or `deny` to dismiss. A reply that
doesn't match any option (like a typed word or an out-of-range number) gets a
correction notification listing the valid replies plus Retry/Deny buttons — the
question stays pending. Multi-select and stacked questions stay informational
only (the body lists every question, option, and description) and you answer at
the terminal. Notifications only fire when the ntfy config is set.

Known limits: ntfy allows 3 buttons and no structured input — multi-select
questions, stacked questions, and typed/custom answers (anything outside the
listed options) require the terminal.

### Auto-approved commands

The following Bash command prefixes are automatically approved without any prompt or notification:

`echo`, `stat`, `ls`, `pwd`, `cat`, `grep`, `find`, `date`, `whoami`, `hostname`, `uname`, `which`, `type`, `file`, `head`, `tail`, `wc`, `sort`, `uniq`, `cut`, `tr`

To permanently allow a tool/command, answer **Yes** at the terminal prompt and select the "Always allow" option. Patterns persist to `settings.local.json` and are auto-approved on future invocations without prompting (Claude-style settings files).

## Providers

`HOOKLINE_PROVIDERS` in config is the whitelist of providers whose hook entries fire:

```bash
HOOKLINE_PROVIDERS="claude codex opencode"   # unset = all installed providers enabled
```

A provider not listed exits its hook silently — that agent behaves as if hookline were absent. Each provider registers its own entry point at install time (`settings.json` hook for Claude-style agents, `hooks.json` merge for Codex, plugin file for OpenCode); the entry calls `hooks/hookline.sh <provider>`, which gates on the registry before running the shared flow.

**On Claude Code:** native remote/mobile approvals already cover claude end-to-end — hookline still registers and works for claude (and Claude-style profiles), but is optional there. Its main job is bringing the same phone-approval UX to the other providers.

### Codex

Codex support rides codex's own `PermissionRequest` hook — merged into `~/.codex/hooks.json` at install (existing hooks in the file are preserved, codex config untouched). Four things to know:

1. **Trust it once.** Open codex, run `/hooks`, and review the hookline entry. Codex silently skips untrusted hooks until you do; `hookline doctor` and `hookline status` both report registered/trusted state.
2. **An approval must actually fire.** hookline only sees requests codex chooses to ask about — that depends on your codex `approval_policy` and sandbox settings. If codex auto-approves or auto-denies by itself, no prompt reaches the hook and no phone notification is sent.
3. **Scope is `Bash`, `apply_patch`, and MCP tools (`mcp__*`).** MCP approvals go through the same decline → menu → phone-answer flow.
4. **The hook declines first, then injects keys.** An empty decision hands the request back to codex's own approval menu (so the terminal looks completely normal); when the phone answers, the watcher sends Enter (approve) or Esc (cancel) into the tmux pane that owns the prompt — or the frontmost window outside tmux.

### Adding an adapter

1. Create `hooks/adapters/<provider>.sh` implementing the adapter interface documented at the top of `hooks/core.sh`: normalize stdin JSON, extract the Bash command, parse an allowlist source, emit the provider's decision JSON, build the notification body, expose a local-progress counter, and inject/resolve allow|deny.
2. Register the provider's entry point (settings hook, plugin, etc.) to invoke `hookline.sh <provider>` with the raw payload.
3. Set `ADAPTER_RESPONSE_ONLY=1` when the daemon must not inject tmux keys for this provider — either the provider resolves decisions itself (reply API) or its prompt needs a different key profile than the daemon's built-in claude keys (codex: Enter/Esc from the hook-side watcher instead).
4. Add golden cases in `scripts/hook-golden.sh`, then run `just lint && just golden`.

## Configuration

Config lives at `~/.config/hookline/config`:

```bash
HOOKLINE_TOPIC="your-ntfy-topic"         # required — subscribe to this in the ntfy app
HOOKLINE_NTFY_SERVER="https://ntfy.sh"   # change for self-hosted ntfy
HOOKLINE_GRACE_PERIOD=20                 # seconds before phone notification fires
HOOKLINE_PHONE_TIMEOUT=900              # seconds to wait for phone response (15 min)
HOOKLINE_EXTENDED_WAIT=3600             # extra seconds the watcher listens after the phone timeout (0 disables)
HOOKLINE_EXTENDED_INTERVAL=180          # cadence of extended-window checks (seconds)
HOOKLINE_MAX_RETRIES=3                   # number of Retry button taps allowed
HOOKLINE_NTFY_USERNAME=""               # for self-hosted ntfy with auth
HOOKLINE_NTFY_PASSWORD=""               # for self-hosted ntfy with auth
HOOKLINE_PROVIDERS="claude opencode"    # provider registry; unset = all enabled
```

Changes take effect immediately — no reinstall needed. `hookline setup` walks through
all of it (transport, topic, subscription QR, tmux check, live test) without editing
files by hand.

## CLI

```bash
hookline setup              # guided setup: transport, topic + QR, tmux check, live test
hookline status               # config, daemon status (heartbeat/SSE ages), connectivity, recent log
hookline doctor               # diagnose the whole chain; fixes a dead/hung daemon
hookline topic                # show the current ntfy topic
hookline topic <name>         # switch topic, update config, restart daemon
hookline daemon start         # start the daemon
hookline daemon stop          # stop the daemon
hookline daemon restart       # restart the daemon
hookline daemon status        # daemon pid, sessions, pending approvals, heartbeat/SSE ages
hookline patterns             # list allowlist entries (project + global settings)
hookline remove-pattern <p>   # drop one entry (`--global` for the global file)
hookline clear-patterns       # wipe the project allowlist (`--global` for global)
```

If phone notifications stop arriving, run `hookline doctor` — it checks the
interpreter, config, hook registration, daemon liveness (real socket ping plus
heartbeat ages), launchd jobs, and ntfy reachability, and restarts a dead or
hung daemon automatically.

## Test

```bash
just hooks         # enable in-repo git hooks (pre-commit doc sync, pre-push gates)
just check-gates  # every gate CI runs, in one command (the single source of truth)
just lint         # shellcheck the shell scripts + py_compile the Python files
just golden         # hook stdout contract tests (sandboxed, no network)
just test-daemon    # daemon unit tests (registry, routing, heartbeat, watchdog)
just test-plugin    # opencode plugin unit tests (node --test)
just doctor-test    # sandboxed `hookline doctor` report tests
just status-test    # sandboxed `hookline status` report tests
just patterns-test  # sandboxed `hookline patterns`/`remove-pattern`/`clear-patterns` tests
just install-test   # sandboxed install/uninstall round-trip tests
just release-smoke-test # sandboxed release smoke check tests (fake gh, no network)
bash scripts/test.sh
```

`scripts/test.sh` sends a test notification with Allow/Deny buttons and reports
the response; the others run offline and also gate CI (`ci.yml` runs exactly
`just check-gates`). `just release-smoke`
asserts the latest GitHub release tag matches `VERSION` (needs gh auth) and
runs in CI right after every release.

## Logs

```bash
tail -f ~/.local/share/hookline/hookline.log   # hook log
tail -f ~/.local/share/hookline/daemon.log     # daemon log (capped at 512KB + daemon.log.1 backup)
tail -f ~/.local/share/hookline/watchdog.log   # watchdog restarts
```

## Uninstall

```bash
bash uninstall.sh
```

Removes the hook from Claude settings, the Codex `PermissionRequest` entry, the
OpenCode plugin, the daemon and watchdog launchd jobs, the CLI, and installed
files. Optionally removes config and logs.

## Terminal support

| Terminal | Method | Notes |
|----------|--------|-------|
| tmux | `tmux send-keys` | Focus-independent; works with any terminal inside tmux |
| iTerm2 | AppleScript | Requires Accessibility permission for iTerm2 |
| Terminal.app | AppleScript | Requires Accessibility permission for Terminal |
| WezTerm | AppleScript | Requires Accessibility permission for WezTerm |
| Other | AppleScript (frontmost) | Targets whichever app is in focus |
| OpenCode TUI | Reply API (no injection) | The plugin answers the prompt in-process; no terminal focus or Accessibility needed |
| Codex TUI | `tmux send-keys` (own pane) / AppleScript | `PermissionRequest` declines → codex's own approval menu shows; phone answer injects Enter (approve) / Esc (cancel) into the pane that owns the prompt |

For the AppleScript terminals, keystroke injection is performed by the hook process (a child of your terminal), so macOS Accessibility permission is only needed for the terminal app itself — never for a background process. tmux injection uses `tmux send-keys` (run by the daemon) and needs no Accessibility permission at all.

## Security

The ntfy topic name is your shared secret — anyone who knows it can send you notifications or respond to your approval requests. Use a unique, hard-to-guess name. For stronger isolation, self-host ntfy with auth and set `HOOKLINE_NTFY_SERVER`, `HOOKLINE_NTFY_USERNAME`, and `HOOKLINE_NTFY_PASSWORD` in config.

See [ntfy.sh access control](https://docs.ntfy.sh/config/#access-control) for auth options.

## Compared to alternatives

[claude-remote-approver](https://github.com/yuuichieguchi/claude-remote-approver) does something similar. hookline's differentiating features:

- **Grace period** — no stale phone notifications when you're at the terminal
- **Local-answer detection** — counts conversation entries, not raw lines, so agent metadata writes can't fake an answer
- **Keystroke injection** — terminal prompt auto-dismisses when phone responds (reply-API providers resolve in-process instead)
- **SSE-based daemon** — persistent connection for instant response; no polling delay
- **Retry button** — instant resend without re-waiting the grace period
- **Typed replies** — option numbers/letters plus `retry`/`deny` words from the ntfy channel; invalid replies get a correction notification
- **Extended window** — late answers still land for up to an hour after the phone timeout
- **Fallback mode** — works without the daemon via inline polling
- **Multi-provider registry** — Claude, Codex, OpenCode, and adapter-shaped future agents behind one core

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) — local testing (`just check-gates`),
how to add a provider adapter or notification backend, and the PR process.

## License

MIT
