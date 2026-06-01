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
          → Tap Allow / Always / Retry
            → Keystroke injected → terminal prompt dismissed
```

Uses Claude Code's [hooks system](https://docs.anthropic.com/en/docs/claude-code/hooks) (`PreToolUse` event) to intercept tool permission prompts before they are shown.

## Requirements

- macOS with [iTerm2](https://iterm2.com) (keystroke injection requires AppleScript + iTerm2)
- `bash`, `jq`, `curl`
- [ntfy app](https://ntfy.sh) on your phone (iOS / Android)

## Install

```bash
git clone https://github.com/yourusername/hookline.git
cd hookline
bash install.sh
```

The installer will:

1. Check dependencies (`jq`, `curl`)
2. Prompt for an ntfy topic name (or generate a random one)
3. Write config to `~/.config/hookline/config`
4. Install the hook to `~/.local/share/hookline/hooks/hookline.sh`
5. Register the hook in `~/.claude/settings.json`

Then open the ntfy app and subscribe to your topic.

## Usage

Use Claude Code normally. When a permission prompt fires:

- **At your terminal** — answer as usual. No phone notification is sent.
- **Away from your terminal** — after 20 seconds, a push notification arrives on your phone.

### Phone notification buttons

| Button | Action |
|--------|--------|
| **Allow** | Approves this one request; terminal prompt auto-dismisses |
| **Always** | Approves + saves pattern to project allowlist (no more prompts for this tool/command) |
| **Deny** | Rejects the request; terminal prompt auto-dismisses with denial |

### Auto-approved commands

The following Bash command prefixes are automatically approved without any prompt or notification:

`echo`, `stat`, `ls`, `pwd`, `cat`, `grep`, `find`, `date`, `whoami`, `hostname`, `uname`, `which`, `type`, `file`, `head`, `tail`, `wc`, `sort`, `uniq`, `cut`, `tr`

Patterns saved via **Always** are also auto-approved on future invocations.

## Configuration

Config lives at `~/.config/hookline/config`:

```bash
HOOKLINE_TOPIC="your-ntfy-topic"         # required — subscribe to this in the ntfy app
HOOKLINE_NTFY_SERVER="https://ntfy.sh"   # change for self-hosted ntfy
HOOKLINE_GRACE_PERIOD=20                 # seconds before phone notification fires
HOOKLINE_PHONE_TIMEOUT=60               # seconds to wait for phone response
```

Changes take effect immediately — no reinstall needed.

## Test

```bash
bash scripts/test.sh
```

Sends a test notification with Allow/Deny buttons and reports the response.

## Logs

```bash
tail -f ~/.local/share/hookline/hookline.log
```

## Uninstall

```bash
bash uninstall.sh
```

Removes the hook from Claude settings and installed files. Optionally removes config and logs.

## Security

The ntfy topic name is your shared secret — anyone who knows it can send you notifications or respond to your approval requests. Use a unique, hard-to-guess name. For stronger isolation, self-host ntfy and set `HOOKLINE_NTFY_SERVER` in config.

See [ntfy.sh access control](https://docs.ntfy.sh/config/#access-control) for auth options.

## Compared to alternatives

[claude-remote-approver](https://github.com/yuuichieguchi/claude-remote-approver) does something similar. hookline's differentiating features:

- **Grace period** — no stale phone notifications when you're at the terminal
- **Transcript detection** — reliably detects local answers using session line counts
- **Keystroke injection** — terminal prompt auto-dismisses when phone responds
- **Polling over SSE** — avoids ntfy rate-limit issues from too many open connections
- **Retry button** — instant resend without re-waiting the grace period

## License

MIT
