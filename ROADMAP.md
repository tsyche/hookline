# hookline Roadmap

## Goals

hookline should be installable and usable by anyone in under 5 minutes with nothing but a Mac, a phone, and an ntfy account. Every feature beyond that is an opt-in upgrade — not a requirement.

**Notification transport tiers (all first-class, user's choice):**
- **ntfy.sh public** — zero friction, works immediately, free; rate limits only a concern for very heavy use
- **Self-hosted ntfy** — full control, no rate limits, ~$5/mo VPS or existing server; recommended for daily drivers
- **Direct / relay-free** — Tailscale or VPN; no third-party services at all; advanced but genuinely accessible via the setup wizard
- **Pluggable backends** — Gotify, Telegram, Pushover, or custom; for users who already have preferred infrastructure

The setup wizard is what makes all tiers accessible. It should ask the right questions, explain tradeoffs plainly, and handle configuration — no manual file editing required.

## v1.1 — Current (stable)

- [x] PreToolUse hook intercepts Bash, Edit, Write, NotebookEdit
- [x] Instant terminal prompt — no delay for local users
- [x] Transcript line-count detection for reliable local-answer detection
- [x] Configurable grace period and phone timeout via `HOOKLINE_GRACE_PERIOD` / `HOOKLINE_PHONE_TIMEOUT`
- [x] ntfy.sh phone notifications with **Allow / Deny / Retry** buttons
- [x] Human-readable notification messages (file paths, commands — not raw JSON)
- [x] Keystroke injection to auto-dismiss terminal prompt when phone responds
- [x] **Always Allow** from terminal saves pattern to project `settings.local.json` allowlist
- [x] Built-in safe-command prefix auto-approval (echo, grep, cat, ls, etc.)
- [x] Auto-retry on notification timeout (keeps resending until you respond)
- [x] Polling-based phone response (avoids ntfy SSE rate limits)
- [x] Self-hosted ntfy support via `HOOKLINE_NTFY_SERVER`
- [x] Install / uninstall / test scripts

## v1.2 — Near-term

- [x] **ntfy Basic Auth** — `HOOKLINE_NTFY_USERNAME` / `HOOKLINE_NTFY_PASSWORD` wired into all curl calls
- [x] **`hookline status` command** — config, hook registration, connectivity ping, last 10 log lines

1. **Setup wizard** (~2–3h)
   - `hookline setup` replaces manual config editing with a guided walkthrough anyone can follow
   - Asks: which transport? ntfy.sh public (default, zero config) → self-hosted ntfy (requires item 1) → direct/Tailscale (requires daemon, v1.3)
   - For ntfy.sh: generate or enter topic, print QR code for phone subscription (requires `qrencode`)
   - For self-hosted ntfy: prompt for server URL + auth credentials; output a ready-to-use `docker-compose.yml`
   - All paths end with a live test notification so user knows it works before they walk away
   - Reruns cleanly to switch transports later; Tailscale path added once daemon ships

2. **AskUserQuestion hook** (~3–4h)
   - Route Claude's interactive questions to phone with multi-button answers
   - Split questions with >3 options across multiple notifications
   - Matches [claude-remote-approver](https://github.com/yuuichieguchi/claude-remote-approver) feature parity

3. **Pattern management CLI** (~2–3h)
   - `hookline patterns` — list current allowlist
   - `hookline remove-pattern <pattern>` — remove without hand-editing JSON
   - `hookline clear-patterns` — wipe project allowlist

4. **CONTRIBUTING.md + CI** (~1–2h)
   - CONTRIBUTING.md: how to add a notification backend, how to test the hook locally, PR process
   - GitHub Actions: `shellcheck` on hookline.sh and install.sh to catch syntax errors before release
   - Essential for a FOSS project inviting contributions; low effort, high community signal

## v1.3 — Medium-term

- **Per-project config** — `.hookline` file at project root to override grace period, add project-specific safe patterns, set notification priority; loaded in addition to `~/.config/hookline/config`
- **Snooze mode** — "I'm at my desk for 60 min, skip phone notifications" toggle via `hookline snooze 60` or a phone button; sets a lock file the background process checks
- **hookline daemon + TTY-agnostic injection** — replace per-invocation osascript with a small always-running daemon that maintains a session registry (session ID → TTY/method) and routes phone responses to the correct session using the best available injection method: `tmux send-keys` if in tmux, terminal-specific AppleScript otherwise, with `TIOCSTI` TTY injection as a future option (currently restricted on macOS 12+); solves both multi-session and terminal portability in one architectural move (see [design notes](#multi-session-design))
- **Idle-aware grace period** — detect system idle time; skip grace period and notify immediately when machine has been idle
- **PostToolUse feedback notifications** — optional low-priority phone notification after a tool completes showing what changed (e.g., "Edit: modified 3 lines in src/app.ts")
- **Tool-aware notification priority** — writes to sensitive paths (`/etc`, repo root) get high-priority ntfy; `/tmp` writes get low priority

## v1.4 — Future

- **Pluggable notification backends** — abstract the notify/poll layer behind a backend interface so hookline isn't ntfy-specific; ship adapters for Gotify (open source, self-hostable, ntfy-compatible API), Telegram bot (free, no rate limits, action buttons), and Pushover; community can add others without touching core
- **Direct mode via Tailscale / VPN** — run a tiny local HTTP server on the Mac; phone polls it directly over Tailscale IP or VPN — zero relay dependency, no third-party service involved; ideal endgame for users already on Tailscale
- **hookline relay (self-hostable)** — ship a minimal relay server component (single binary or Docker image) as a fully independent ntfy replacement; deploy on any VPS; uses same poll-based protocol as current ntfy integration
- **Terminal emulator portability** — support Terminal.app, Warp, Kitty, Ghostty (detect via `$TERM_PROGRAM`); handled as part of the daemon work above
- **Linux support** — replace `osascript` keystroke injection with `xdotool` / `ydotool`
- **Notification content control** — configurable truncation; redact sensitive path segments
- **Approval history** — queryable log of what was approved/denied, when, and from where (terminal vs. phone)
- **Always-deny patterns** — companion to allowlist for commands that should always be blocked
- **Time-based rules** — configurable schedule (e.g. notify immediately after 6pm)
- **CHANGELOG** — versioned release notes; important signal of project health for FOSS adopters

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

## Relay-free Design (Tailscale / VPN Direct Mode)

Currently hookline requires a relay because the phone and Mac aren't directly reachable from each other over the internet. With Tailscale (free, easy to set up on any device) or a VPN, they share a private network and can talk directly — no relay needed.

**Why this is accessible to anyone:** Tailscale has a generous free tier, runs on iOS/Android/macOS/Linux, and takes ~5 minutes to set up. The setup wizard handles detection and configuration. Users don't need to understand networking.

**Proposed architecture:**

The hookline daemon (see above) also exposes a small HTTP server on a configurable port (default `7676`). When direct mode is configured, it binds to the Tailscale or VPN interface IP.

- Hook fires → daemon registers the pending approval at `GET /pending`
- Phone polls `http://<device-ip>:7676/pending` every few seconds
- Phone approves via `POST /respond` with decision
- Daemon receives response and injects keystroke as usual

The companion mobile interface could be:
- A minimal PWA served from the daemon itself (no app store, works in any mobile browser)
- An iOS/Android Shortcut that polls the endpoint
- Eventually a dedicated companion app

No third-party services, no rate limits, no single point of failure. The daemon architecture makes this a natural extension — the same daemon handles both relay and direct modes, switching based on config.
