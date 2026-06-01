# hookline Roadmap

## v1.1 — Current (stable)

- [x] PreToolUse hook intercepts Bash, Edit, Write, NotebookEdit
- [x] Instant terminal prompt — no delay for local users
- [x] Transcript line-count detection for reliable local-answer detection
- [x] Configurable grace period and phone timeout via `HOOKLINE_GRACE_PERIOD` / `HOOKLINE_PHONE_TIMEOUT`
- [x] ntfy.sh phone notifications with **Allow / Always / Deny** buttons
- [x] Human-readable notification messages (file paths, commands — not raw JSON)
- [x] Keystroke injection to auto-dismiss terminal prompt when phone responds
- [x] **Always Allow** saves pattern to project `settings.local.json` allowlist
- [x] Built-in safe-command prefix auto-approval (echo, grep, cat, ls, etc.)
- [x] Polling-based phone response (avoids ntfy SSE rate limits)
- [x] Self-hosted ntfy support via `HOOKLINE_NTFY_SERVER`
- [x] Install / uninstall / test scripts

## v1.2 — Near-term

1. **AskUserQuestion hook** (~3–4h)
   - Route Claude's interactive questions to phone with multi-button answers
   - Split questions with >3 options across multiple notifications
   - Matches [claude-remote-approver](https://github.com/yuuichieguchi/claude-remote-approver) feature parity

5. **Self-hosted ntfy auth** (~1h)
   - Add `HOOKLINE_NTFY_USERNAME` / `HOOKLINE_NTFY_PASSWORD` to config
   - Pass as Basic Auth header on all curl calls
   - Required for private ntfy deployments

6. **Pattern management CLI** (~2–3h)
   - `hookline patterns` — list current allowlist
   - `hookline remove-pattern <pattern>` — remove without hand-editing JSON
   - `hookline clear-patterns` — wipe project allowlist

## v1.3 — Medium-term

- **Per-project config** — `.hookline` file at project root to override grace period, add project-specific safe patterns, set notification priority; loaded in addition to `~/.config/hookline/config`
- **Snooze mode** — "I'm at my desk for 60 min, skip phone notifications" toggle via `hookline snooze 60` or a phone button; sets a lock file the background process checks
- **hookline daemon + TTY-agnostic injection** — replace per-invocation osascript with a small always-running daemon that maintains a session registry (session ID → TTY/method) and routes phone responses to the correct session using the best available injection method: `tmux send-keys` if in tmux, terminal-specific AppleScript otherwise, with `TIOCSTI` TTY injection as a future option (currently restricted on macOS 12+); solves both multi-session and terminal portability in one architectural move (see [design notes](#multi-session-design))
- **Idle-aware grace period** — detect system idle time; skip grace period and notify immediately when machine has been idle
- **PostToolUse feedback notifications** — optional low-priority phone notification after a tool completes showing what changed (e.g., "Edit: modified 3 lines in src/app.ts")
- **Tool-aware notification priority** — writes to sensitive paths (`/etc`, repo root) get high-priority ntfy; `/tmp` writes get low priority

## v1.4 — Future

- **Terminal emulator portability** — support Terminal.app, Warp, Kitty, Ghostty (detect via `$TERM_PROGRAM`); handled as part of the daemon work above
- **Linux support** — replace `osascript` keystroke injection with `xdotool` / `ydotool`
- **Notification content control** — configurable truncation; redact sensitive path segments
- **Approval history** — queryable log of what was approved/denied, when, and from where (terminal vs. phone)
- **Always-deny patterns** — companion to allowlist for commands that should always be blocked
- **QR code setup** — print ntfy topic URL as QR code during install for easy phone subscription (requires `qrencode`)
- **Time-based rules** — configurable schedule (e.g. notify immediately after 6pm)

---

## Multi-session & Terminal-agnostic Design

Keystroke injection currently targets whatever iTerm2 window is in focus, which breaks with multiple Claude Code sessions open simultaneously and doesn't work in other terminal emulators.

**Proposed architecture: hookline daemon**

A small always-running background agent that:
1. Listens on a Unix socket (`~/.local/share/hookline/daemon.sock`)
2. On hook fire, registers `session_id → TTY + environment` (captured from hook input)
3. Phone listener sends decision to daemon socket instead of doing osascript inline
4. Daemon looks up the session and injects using the best available method:
   - `$TMUX` set → `tmux send-keys -t <pane>` (focus-independent, terminal-agnostic)
   - `$TERM_PROGRAM=iTerm.app` → AppleScript targeting specific session by TTY
   - `$TERM_PROGRAM=WezTerm|Ghostty|...` → terminal-specific APIs
   - Linux → `xdotool type` targeting window by PID
   - Last resort → `TIOCSTI` TTY ioctl (restricted on macOS 12+, requires entitlement)

This solves multi-session and terminal portability in one move. tmux users get it for free immediately; non-tmux users get best-effort per terminal emulator.
