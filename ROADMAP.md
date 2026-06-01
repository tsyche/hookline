# hookline Roadmap

## v1.0 — Current (stable)

- [x] PreToolUse hook intercepts Bash, Edit, Write, NotebookEdit
- [x] Instant terminal prompt — no delay for local users
- [x] Transcript line-count detection for reliable local-answer detection
- [x] 20-second grace period: local answers suppress phone notification
- [x] ntfy.sh phone notifications with **Allow / Always / Retry** buttons
- [x] Keystroke injection to auto-dismiss terminal prompt when phone responds
- [x] **Always Allow** saves pattern to project `settings.local.json` allowlist
- [x] Built-in safe-command prefix auto-approval (echo, grep, cat, ls, etc.)
- [x] Retry button resends notification immediately (no additional grace period)
- [x] Polling-based phone response (avoids ntfy SSE rate limits)
- [x] Install / uninstall / test scripts

## v1.1 — Near-term

1. **Wire up config variables** (~30 min)
   - Hook currently hardcodes `sleep 20` and `PHONE_TIMEOUT=60`; `install.sh` already writes `HOOKLINE_GRACE_PERIOD` and `HOOKLINE_PHONE_TIMEOUT` to config but hook ignores them
   - Fix: read those vars in the hook; fall back to defaults if unset
   - Almost done — just needs 2 lines changed

2. **Notification content formatting** (~1–2h)
   - Phone currently shows raw JSON: `{"file_path":"/path","content":"..."}`
   - Extract and display human-readable fields: file path for Write/Edit, command for Bash
   - Truncate long values cleanly; strip newlines and control chars

3. **Deny via notification body tap** (~1h)
   - ntfy supports a `click` action that fires when the user taps the notification body (not a button)
   - Use this as Deny — keeps the 3 action buttons as Allow/Always/Retry
   - No button layout changes needed

4. **AskUserQuestion hook** (~3–4h)
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

## v1.2 — Medium-term

- **Per-project config** — `.hookline` file at project root to override grace period, add project-specific safe patterns, set notification priority; loaded in addition to `~/.config/hookline/config`
- **Snooze mode** — "I'm at my desk for 60 min, skip phone notifications" toggle via `hookline snooze 60` or a phone button; sets a lock file the background process checks
- **Multi-session keystroke injection** — map session IDs to iTerm2 tab/session identifiers via AppleScript; inject into the correct window even when not in focus (see [design notes](#multi-session-design))
- **Idle-aware grace period** — detect system idle time; skip grace period and notify immediately when machine has been idle
- **PostToolUse feedback notifications** — optional low-priority phone notification after a tool completes showing what changed (e.g., "Edit: modified 3 lines in src/app.ts")
- **Tool-aware notification priority** — writes to sensitive paths (`/etc`, repo root) get high-priority ntfy; `/tmp` writes get low priority

## v1.3 — Future

- **Terminal emulator portability** — support Terminal.app, Warp, Kitty, Ghostty (detect via `$TERM_PROGRAM`)
- **Linux support** — replace `osascript` keystroke injection with `xdotool` / `ydotool`
- **Notification content control** — configurable truncation; redact sensitive path segments
- **Approval history** — queryable log of what was approved/denied, when, and from where (terminal vs. phone)
- **Always-deny patterns** — companion to allowlist for commands that should always be blocked
- **QR code setup** — print ntfy topic URL as QR code during install for easy phone subscription (requires `qrencode`)
- **Time-based rules** — configurable schedule (e.g. notify immediately after 6pm)

---

## Multi-session Design

Keystroke injection currently targets whatever iTerm2 window/tab is in focus. This works for single-session use but breaks when multiple Claude Code tabs are open simultaneously.

Proposed approach:
- At hook fire time, capture the Claude Code process's controlling TTY from the hook's `session_id` and process tree
- Map session IDs to iTerm2 tab/session identifiers via AppleScript introspection
- Inject keystrokes directly to the matched session regardless of focus

Tracked as a future feature — contributions welcome.
