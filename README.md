# hookline

Approve [Claude Code](https://docs.anthropic.com/en/docs/claude-code) permission prompts from your phone via [ntfy.sh](https://ntfy.sh).

When Claude needs permission to run a tool, the terminal prompt appears instantly. If you answer at the terminal, your phone is never notified. If you walk away, a push notification arrives on your phone after a 20-second grace period — tap to respond, and the terminal prompt auto-dismisses.

## How It Works

```
Claude Code triggers PreToolUse hook
  → Terminal prompt appears immediately
  → 20-second grace period starts
    ├── Answered at terminal? → phone stays quiet
    └── No answer? → ntfy.sh notification sent to phone
          → Tap Allow / Deny / Retry
            → Keystroke injected → terminal prompt dismissed
```

Uses Claude Code's [hooks system](https://docs.anthropic.com/en/docs/claude-code/hooks) (`PreToolUse` event) to intercept tool permission prompts before they are shown. A background daemon maintains a persistent SSE connection to ntfy so phone responses arrive instantly.

## Requirements

- macOS (Terminal.app, iTerm2, WezTerm, or tmux — see [terminal support](#terminal-support))
- `bash`, `jq`, `curl`, `python3`
- [ntfy app](https://ntfy.sh) on your phone (iOS / Android)

## Install

```bash
git clone https://github.com/yourusername/hookline.git
cd hookline
bash install.sh
```

The installer will:

1. Check dependencies (`jq`, `curl`, `python3`)
2. Prompt for an ntfy topic name (or generate a random one)
3. Write config to `~/.config/hookline/config`
4. Install the hook to `~/.local/share/hookline/hooks/hookline.sh`
5. Install the daemon to `~/.local/share/hookline/daemon/hookline-daemon`
6. Register the daemon with launchd (starts automatically on login)
7. Register the hook in `~/.claude/settings.json`

Then open the ntfy app and subscribe to your topic (and `your-topic-response`).

## Usage

Use Claude Code normally. When a permission prompt fires:

- **At your terminal** — answer as usual. No phone notification is sent.
- **Away from your terminal** — after 20 seconds, a push notification arrives on your phone.

### Phone notification buttons

| Button | Action |
|--------|--------|
| **Allow** | Approves this one request; terminal prompt auto-dismisses |
| **Deny** | Rejects the request; terminal prompt auto-dismisses with denial |
| **Retry** | Resends a fresh notification (useful when you catch it late) |

### Auto-approved commands

The following Bash command prefixes are automatically approved without any prompt or notification:

`echo`, `stat`, `ls`, `pwd`, `cat`, `grep`, `find`, `date`, `whoami`, `hostname`, `uname`, `which`, `type`, `file`, `head`, `tail`, `wc`, `sort`, `uniq`, `cut`, `tr`

To permanently allow a tool/command, answer **Yes** at the terminal prompt and select the "Always allow" option. Patterns persist to `settings.local.json` and are auto-approved on future invocations without prompting.

## Configuration

Config lives at `~/.config/hookline/config`:

```bash
HOOKLINE_TOPIC="your-ntfy-topic"         # required — subscribe to this in the ntfy app
HOOKLINE_NTFY_SERVER="https://ntfy.sh"   # change for self-hosted ntfy
HOOKLINE_GRACE_PERIOD=20                 # seconds before phone notification fires
HOOKLINE_PHONE_TIMEOUT=900              # seconds to wait for phone response (15 min)
HOOKLINE_MAX_RETRIES=3                   # number of Retry button taps allowed
HOOKLINE_NTFY_USERNAME=""               # for self-hosted ntfy with auth
HOOKLINE_NTFY_PASSWORD=""               # for self-hosted ntfy with auth
```

Changes take effect immediately — no reinstall needed.

## CLI

```bash
hookline status               # show config, daemon status, connectivity, recent log
hookline daemon start         # start the daemon
hookline daemon stop          # stop the daemon
hookline daemon restart       # restart the daemon
hookline daemon status        # show daemon pid, active sessions, pending approvals
```

## Test

```bash
bash scripts/test.sh
```

Sends a test notification with Allow/Deny buttons and reports the response.

## Logs

```bash
tail -f ~/.local/share/hookline/hookline.log   # hook log
tail -f ~/.local/share/hookline/daemon.log     # daemon log
```

## Uninstall

```bash
bash uninstall.sh
```

Removes the hook from Claude settings and installed files. Optionally removes config and logs.

## Terminal support

| Terminal | Method | Notes |
|----------|--------|-------|
| tmux | `tmux send-keys` | Focus-independent; works with any terminal inside tmux |
| iTerm2 | AppleScript | Requires Accessibility permission for iTerm2 |
| Terminal.app | AppleScript | Requires Accessibility permission for Terminal |
| WezTerm | AppleScript | Requires Accessibility permission for WezTerm |
| Other | AppleScript (frontmost) | Targets whichever app is in focus |

Keystroke injection is performed by the hook process (a child of your terminal), so macOS accessibility permissions are only needed for the terminal app itself — not for any background process.

## Security

The ntfy topic name is your shared secret — anyone who knows it can send you notifications or respond to your approval requests. Use a unique, hard-to-guess name. For stronger isolation, self-host ntfy with auth and set `HOOKLINE_NTFY_SERVER`, `HOOKLINE_NTFY_USERNAME`, and `HOOKLINE_NTFY_PASSWORD` in config.

See [ntfy.sh access control](https://docs.ntfy.sh/config/#access-control) for auth options.

## Compared to alternatives

[claude-remote-approver](https://github.com/yuuichieguchi/claude-remote-approver) does something similar. hookline's differentiating features:

- **Grace period** — no stale phone notifications when you're at the terminal
- **Transcript detection** — reliably detects local answers using session line counts
- **Keystroke injection** — terminal prompt auto-dismisses when phone responds
- **SSE-based daemon** — persistent connection for instant response; no polling delay
- **Retry button** — instant resend without re-waiting the grace period
- **Fallback mode** — works without the daemon via inline polling

## License

MIT
