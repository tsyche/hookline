# hookline Roadmap

## Goals

hookline should be installable and usable by anyone in under 5 minutes with nothing but a Mac, a phone, and an ntfy account. Every feature beyond that is an opt-in upgrade — not a requirement.

**Notification transport tiers (all first-class, user's choice):**
- **ntfy.sh public** — zero friction, works immediately, free; rate limits only a concern for very heavy use
- **Self-hosted ntfy** — full control, no rate limits, ~$5/mo VPS or existing server; recommended for daily drivers
- **Direct / relay-free** — Tailscale or VPN; no third-party services at all; advanced but genuinely accessible via the setup wizard
- **Pluggable backends** — Gotify, Telegram, Pushover, or custom; for users who already have preferred infrastructure

The setup wizard is what makes all tiers accessible. It should ask the right questions, explain tradeoffs plainly, and handle configuration — no manual file editing required.

## v1.1 — Stable

- [x] PreToolUse hook intercepts Bash, Edit, Write, NotebookEdit
- [x] Instant terminal prompt — no delay for local users
- [x] Transcript line-count detection for reliable local-answer detection
- [x] Configurable grace period and phone timeout via `HOOKLINE_GRACE_PERIOD` / `HOOKLINE_PHONE_TIMEOUT`
- [x] ntfy.sh phone notifications with **Allow / Deny / Retry** buttons
- [x] Human-readable notification messages (file paths, commands — not raw JSON)
- [x] Keystroke injection to auto-dismiss terminal prompt when phone responds
- [x] **Always Allow** from terminal saves pattern to project `settings.local.json` allowlist
- [x] Built-in safe-command prefix auto-approval (echo, grep, cat, ls, etc.)
- [x] Self-hosted ntfy support via `HOOKLINE_NTFY_SERVER`
- [x] Install / uninstall / test scripts

## v1.2 — Current (stable)

- [x] **ntfy Basic Auth** — `HOOKLINE_NTFY_USERNAME` / `HOOKLINE_NTFY_PASSWORD` wired into all curl calls
- [x] **`hookline status` command** — config, hook registration, daemon status, connectivity ping, last 10 log lines
- [x] **hookline daemon** — persistent Python daemon with SSE connection for instant phone response (no polling delay); session registry maps session IDs to TTY/terminal/tmux pane; response file IPC keeps keystroke injection in the hook's process tree (no extra macOS accessibility permissions); graceful fallback to inline polling when daemon is down
- [x] **Multi-terminal injection** — iTerm2, Terminal.app, WezTerm via AppleScript; tmux via `send-keys` (focus-independent); frontmost-app fallback for others
- [x] **Zombie prevention** — per-session lock file (parent writes `$!`), conditional EXIT trap, max retry cap, global ntfy throttle

1. **Setup wizard** (~2–3h)
   - `hookline setup` replaces manual config editing with a guided walkthrough anyone can follow
   - Asks: which transport? ntfy.sh public (default, zero config) → self-hosted ntfy → direct/Tailscale (daemon HTTP server)
   - For ntfy.sh: generate or enter topic, print QR code for phone subscription (requires `qrencode`)
   - For self-hosted ntfy: prompt for server URL + auth credentials; output a ready-to-use `docker-compose.yml`
   - Detects whether tmux is installed and active; recommends it for full multi-session support; offers `brew install tmux` if missing
   - If not using tmux, warns that keystroke injection only works reliably in a single terminal window — concurrent Claude sessions in separate tabs/splits won't both get focus-independent injection
   - All paths end with a live test notification so user knows it works before they walk away
   - Reruns cleanly to switch transports later

2. **`hookline topic` command** (~30 min)
   - `hookline topic <name>` — update topic in config and restart daemon in one step
   - Avoids manual config editing when switching topics (e.g., after an ntfy ban)
   - Quick win; solves a real recurring pain point

3. **AskUserQuestion hook** (~3–4h)
   - Route Claude's interactive questions to phone with multi-button answers
   - Split questions with >3 options across multiple notifications
   - Matches [claude-remote-approver](https://github.com/yuuichieguchi/claude-remote-approver) feature parity

4. **Pattern management CLI** (~2–3h)
   - `hookline patterns` — list current allowlist
   - `hookline remove-pattern <pattern>` — remove without hand-editing JSON
   - `hookline clear-patterns` — wipe project allowlist

5. **CONTRIBUTING.md + CI** (~1–2h)
   - CONTRIBUTING.md: how to add a notification backend, how to test the hook locally, PR process
   - GitHub Actions: `shellcheck` on hookline.sh and install.sh to catch syntax errors before release
   - Essential for a FOSS project inviting contributions; low effort, high community signal

## v1.3 — Medium-term

- **Multi-session support (tmux)** — already works; each session registers its own `tmux_pane_id` and daemon injects to the correct pane directly
- **Multi-session support (bare terminals)** — per-terminal plumbing to capture a stable window/tab/pane identifier at session registration time and target it precisely at injection time; iTerm2 (AppleScript session ID), WezTerm (`wezterm cli --pane-id`), Terminal.app (window/tab index, fragile); ~2–3h per terminal emulator
- **Snooze mode** — "I'm at my desk for 60 min, skip phone notifications" toggle via `hookline snooze 60` or a phone button; sets a lock file the background process checks
- **Per-project config** — `.hookline` file at project root to override grace period, add project-specific safe patterns, set notification priority; loaded in addition to `~/.config/hookline/config`
- **Idle-aware grace period** — detect system idle time; skip grace period and notify immediately when machine has been idle
- **SSH deep link on timeout notification** — when the prompt expires, the timeout notification already fires with no buttons; add a configurable `HOOKLINE_SSH_URL` (e.g. `blinkshell://open?host=...` for iOS Blink, `ssh://user@host` for others) that attaches as a `view` action button on the timeout notification — one tap gets you to the terminal session after a missed prompt; approval notifications stay at 3 buttons (Allow/Deny/Retry) unchanged
- **PostToolUse feedback notifications** — optional low-priority phone notification after a tool completes showing what changed (e.g., "Edit: modified 3 lines in src/app.ts")
- **Tool-aware notification priority** — writes to sensitive paths (`/etc`, repo root) get high-priority ntfy; `/tmp` writes get low priority

## v1.4 — Future

- **Pluggable notification backends** — abstract the notify/poll layer behind a backend interface so hookline isn't ntfy-specific; ship adapters for Gotify, Telegram bot, and Pushover; community can add others without touching core
- **Direct mode via Tailscale / VPN** — daemon exposes a small HTTP server; phone polls it directly over Tailscale IP or VPN — zero relay dependency; PWA or Shortcut as mobile interface
- **hookline relay (self-hostable)** — minimal relay server (single binary or Docker image) as a fully independent ntfy replacement
- **Linux support** — replace `osascript` keystroke injection with `xdotool` / `ydotool`
- **Notification content control** — configurable truncation; redact sensitive path segments
- **Approval history** — queryable log of what was approved/denied, when, and from where (terminal vs. phone)
- **Always-deny patterns** — companion to allowlist for commands that should always be blocked
- **Time-based rules** — configurable schedule (e.g. notify immediately after 6pm)
- **CHANGELOG** — versioned release notes; important signal of project health for FOSS adopters

---

## Daemon Architecture

The hookline daemon (`~/.local/share/hookline/daemon/hookline-daemon`) is a small Python process managed by launchd (`com.hookline.daemon`). It:

1. Listens on a Unix socket (`~/.local/share/hookline/daemon.sock`) for messages from hook invocations
2. Maintains a persistent SSE connection to the ntfy response topic — phone responses arrive instantly
3. Stores a session registry mapping `session_id → {tty, term_program, tmux_pane}`
4. On response: for tmux sessions, injects via `tmux send-keys` directly; for all others, writes a response file that the hook process (a child of the terminal) reads and acts on — keeping keystroke injection in the process tree that already has macOS Accessibility trust
5. Falls back gracefully: if the daemon is not running, the hook uses inline polling instead

## Relay-free Design (Tailscale / VPN Direct Mode)

Currently hookline requires a relay because the phone and Mac aren't directly reachable from each other over the internet. With Tailscale or a VPN, they share a private network and can talk directly.

The daemon already handles the session registry and response routing. Adding direct mode means:
- Daemon exposes an HTTP endpoint (default port `7676`) bound to the Tailscale/VPN interface
- Phone polls `http://<device-ip>:7676/pending` and POSTs to `/respond`
- Daemon receives response and routes as usual — no ntfy involved

Mobile interface options: minimal PWA served from the daemon, an iOS/Android Shortcut, or eventually a dedicated companion app.
