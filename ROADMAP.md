# hookline Roadmap

> **tl;dr:** active work only — shipped entries (Phases 0–6) live in
> [docs/ledger/ROADMAP_SHIPPED.md](docs/ledger/ROADMAP_SHIPPED.md). `VERSION` is
> the source of truth, and the release workflow tags and publishes on the first main push
> that carries a `VERSION` change. Sections below are **phases** (the same scheme as
> Phases 0–4, house convention across projects), ordered next-up first: Phase 7
> notification/UX → Phase 8 Linux Tier 2 (Tier 1 systemd shipped, acceptance pending)
> → Phase 9 remote control + E2E.

> **Status: multi-provider revival.** hookline was paused in maintenance mode (2026-06)
> when Claude Code shipped native remote/mobile approvals — but that covers **claude
> only**. The revival: the same phone-approval UX for every agent the `ai` alias can
> launch (claude · codex · opencode · grok · local custom providers) via a provider
> registry + adapter architecture. See the archived
> [multi-provider plan](~/.claude/plans/archive/hookline-multi-provider.md) for decisions,
> phases, and gates.
>
> **Naming rule:** app-facing text (README, roadmap, setup/status copy, docs) must never
> name private local providers — use "local" / "custom". Concrete provider ids live only in
> untracked config (`~/.config/hookline/config`) and the code that consumes them.
>
> **Parity note:** for claude, native remote approvals are the primary path — hookline's claude
> adapter stays installed but **default-off** as a toggleable backup. For every other provider,
> hookline is the only approval path. The old parity checklist (away-approval · grace period ·
> instant response · multi-session routing · safe-prefix auto-approve · "always allow"
> persistence · no third-party relay) now applies per-provider rather than as an
> archive-or-keep test for the whole project.
>
> **Releases:** through **v1.8.0 (2026-09-30)** — see [CHANGELOG.md](CHANGELOG.md);
> per-feature history in the [shipped ledger](docs/ledger/ROADMAP_SHIPPED.md). Open
> acceptance runs: Linux Tier 1 on a fresh Ubuntu box.

## Goals

hookline should be installable and usable by anyone in under 5 minutes with nothing but a Mac, a phone, and an ntfy account (Linux Tier 1 landed — systemd installs work; installs elsewhere fail fast with a clear message). Every feature beyond that is an opt-in upgrade — not a requirement.

**Notification transport tiers (all first-class, user's choice):**
- **ntfy.sh public** — zero friction, works immediately, free; rate limits only a concern for very heavy use
- **Self-hosted ntfy** — full control, no rate limits, ~$5/mo VPS or existing server; recommended for daily drivers
- **Direct / relay-free** — Tailscale or VPN; no third-party services at all; advanced but genuinely accessible via the setup wizard
- **Pluggable backends** — Gotify, Telegram, Pushover, or custom; for users who already have preferred infrastructure

The setup wizard is what makes all tiers accessible. It should ask the right questions, explain tradeoffs plainly, and handle configuration — no manual file editing required.

## Recommended Next 3

1. **Notification metadata — know which alert is which at a glance** (~1–2h) — Phase 7 item (Tim add, 2026-09-30)
2. **Typed-reply disambiguation for multiple pending prompts** (~1–2h) — Phase 7 item
3. **Bare-terminal screen capture beyond iTerm2** (~1–2h) — Phase 7 item

> All three are Phase 7 items. Previous rounds (`context`, doctor per-provider checks,
> pattern CLI, CONTRIBUTING.md, in-repo git hooks) shipped 2026-09-29/30 in
> **v1.7.0/v1.8.0** — see the [shipped ledger](docs/ledger/ROADMAP_SHIPPED.md).

## Phase 7 — Medium-term

- **Notification metadata — know which alert is which at a glance** (~1–2h) — with several sessions prompting at once the phone stack is unreadable: title is only `[tmux-session / project] ToolName` (`core.sh` label) and the body opens straight into `$ cmd` — no provider, no work context. Add at minimum the provider to the title (`[claude] …` / `grok …`), and a body header line carrying identifying context (project, `git branch --show-current`, working dir or a short task label) before the command/details; keep every derived sender consistent (prompt, expiry, invalid-reply, `context` summary, daemon retry/feedback — they reuse `notify_title`). Config should be able to drop the context line (quiet mode / privacy). Acceptance: golden cases assert the new title+header shape per provider, all existing cases updated in one pass
- **Typed-reply disambiguation for multiple pending prompts** — today a bare typed reply (`allow`/`deny`/`retry`, or an option number/letter) only resolves when exactly one prompt is pending (`handle_typed_reply` logs and drops otherwise); with 2+ providers prompting at once, buttons still work (they carry `req_id`) but typed text is ignored. Prompt-picker flow: one pending question → number picks its option; several pending → reply `1`/`2` to pick the prompt first, then the option. ~1–2h
- **Bare-terminal screen capture beyond iTerm2** (~1–2h) — watcher-side screenshot
  parsing (grok allow-once row, claude read) reads iTerm2 session contents only; add
  Terminal.app / WezTerm capture with the same graceful no-inject fallback (unreadable
  screen → prompt stays, no keys sent)
- **Per-project config** — `.hookline` file at project root to override grace period, add project-specific safe patterns, set notification priority; loaded in addition to `~/.config/hookline/config`
- **Idle-aware grace period** — detect system idle time; skip grace period and notify immediately when machine has been idle
- **Companion app — one-tap deep link to the right session** — a small Android companion app that registers a custom URL scheme (e.g. `hookline://connect?host=mac&session=hookline`). hookline embeds the connect command (including the exact tmux session for the project that fired) as a `view`-action button on the notification; tapping it opens the app, which fires Termux's `RUN_COMMAND` intent with the *typed* extras Termux needs (boolean `RUN_COMMAND_BACKGROUND=false`, `String[]` arguments) — the thing a bare `ssh://` link or a string-only ntfy broadcast can't do. Lands you directly in the correct session, no manual picker. Why a companion app and not config + ConnectBot/Tasker: Termux registers no URL scheme, and ntfy can only send string intent extras, so the only clean Android paths are (a) ConnectBot as an `ssh://` handler — separate app, bare shell, or (b) a Tasker/MacroDroid bridge — paid/fragile, terrible onboarding. A first-party app owns the whole bridge with zero third-party glue. **Endgame:** the same app can grow a persistent connection straight to the hookline daemon (see [Relay-free Design](#relay-free-design-tailscale--vpn-direct-mode)) — at which point it receives the approval request *and* launches the session in-process, dropping the ntfy dependency on the receive side entirely. (Tracked here after a manual-flow decision: today, a missed prompt just sends a plain "prompt expired" notification and you connect by hand — VPN → Termux → `mac` → pick session.)
  - 🧑 needs-human: Android build, signing, and on-device install
- **PostToolUse feedback notifications** — optional low-priority phone notification after a tool completes showing what changed (e.g., "Edit: modified 3 lines in src/app.ts")
- **Tool-aware notification priority** — writes to sensitive paths (`/etc`, repo root) get high-priority ntfy; `/tmp` writes get low priority

## Phase 8 — Future

- **Pluggable notification backends** — abstract the notify/poll layer behind a backend interface so hookline isn't ntfy-specific; ship adapters for Gotify, Telegram bot, and Pushover; community can add others without touching core
- **Direct mode via Tailscale / VPN** — zero relay dependency; the endpoint design (port `7676`, `/pending`, `/respond`) and mobile interface options (PWA, Shortcut, companion app) are specced in [Relay-free Design](#relay-free-design-tailscale--vpn-direct-mode)
- **hookline relay (self-hostable)** — minimal relay server (single binary or Docker image) as a fully independent ntfy replacement
- **Linux support** — tiered, so tmux users get value first:
  - **Tier 1 — daemon + tmux path: SHIPPED (v1.8.0; fresh-Ubuntu acceptance run
    still pending)** — `systemd --user` units replace the launchd plists (daemon +
    watchdog `StartInterval` → 60s `hookline-watchdog.timer`); `install.sh` /
    `uninstall.sh` / `hookline doctor|status|daemon` / the watchdog branch on the
    detected init system (`systemctl --user` vs `launchctl`; `HOOKLINE_INIT_SYSTEM`
    env override pins it for tests on either OS); the fail-fast guard now allows
    Linux with systemd and still fails fast elsewhere; bare-terminal injection
    (osascript) stays macOS-only — the tmux `send-keys` path is already portable.
    Watch-outs handled: user-bus probe before any write + linger note
    (`loginctl enable-linger`), `~/.config/systemd/user/` unit files, watchdog
    checks `systemctl --user is-enabled` (enabled-but-dead → restart, deliberately
    disabled → stand down)
  - **Tier 2 — bare terminals (~4–6h):** replace frontmost-app `osascript` keystroke
    injection with `xdotool` (X11) / `ydotool` (Wayland, needs uinput + rootless udev);
    terminal detection covers kitty/alacritty/foot/gnome-terminal; focus-dependent,
    same limitation as macOS bare terminals (tmux remains the focus-independent path)
  - Acceptance: fresh Ubuntu/Debian box — one-line install registers systemd units,
    daemon runs, phone notification + Allow/Deny round-trip works in a tmux session
    (**not yet run** — Tier 1 landed in code/tests only)
  - Not in scope: Windows/WSL (separate spike if ever)
- **Notification content control** — configurable truncation; redact sensitive path segments
- **Approval history** — queryable log of what was approved/denied, when, and from where (terminal vs. phone)
- **Always-deny patterns** — companion to allowlist for commands that should always be blocked
- **Time-based rules** — configurable schedule (e.g. notify immediately after 6pm)

## Phase 9 — Remote control + E2E

Feasibility assessed 2026-09-25 — all hard pieces already proven in Phases 0–4.
🧑 needs-human: on-device setup steps throughout.

- [ ] **Full two-way remote control over ntfy** — chat parity with Claude's native remote,
  for every non-Anthropic provider:
  - *Input:* separate control topic → daemon routes per provider — terminal providers via
    `tmux send-keys` (socket-aware path shipped in Phase 3), opencode via plugin →
    `POST /session/{id}/message` (no injection needed)
  - *Output:* `-log` topic as chat history — plugin relays `message.part.updated` deltas;
    adapters tail the transcript; ntfy topic history = scrollback; pushes only for
    "agent finished / needs you"
  - *Phone input:* ntfy app has no inline text reply → iOS Shortcut/Siri action POSTs to
    the control topic (ntfy app keeps the tap-approval buttons)
  - *Watch-outs:* ntfy cache retention (~12h default), delta spam, multi-session targeting
  - 🧑 needs-human: iOS Shortcut/Siri input path and ntfy button routing need on-device setup
- [ ] **End-to-end encryption (E2E)** — protect conversation content itself:
  - AES-256-GCM at the publisher (daemon + opencode plugin); plaintext never leaves the
    machine; ntfy servers only ever see ciphertext
  - Decrypt in a static reader page (WebCrypto; key pasted once → localStorage); page can
    live anywhere since it never holds the key at rest
  - ntfy notifications keep only sanitized titles (no command text) when encryption is on
  - Separate control topic + ntfy auth — full remote control turns the topic into a remote
    shell, auth is not optional
  - Residual risk (documented): ntfy still sees metadata — timing, sizes, topic name;
    self-hosted ntfy closes that too
  - 🧑 needs-human: key paste and decryption verified in a phone browser

---

## Daemon Architecture

Moved to [AGENTS.md](AGENTS.md#stack) — socket, session registry, response routing, and the
inline-polling fallback now live with the code-adjacent stack notes.

## Relay-free Design (Tailscale / VPN Direct Mode)

Currently hookline requires a relay because the phone and Mac aren't directly reachable from each other over the internet. With Tailscale or a VPN, they share a private network and can talk directly.

The daemon already handles the session registry and response routing. Adding direct mode means:
- Daemon exposes an HTTP endpoint (default port `7676`) bound to the Tailscale/VPN interface
- Phone polls `http://<device-ip>:7676/pending` and POSTs to `/respond`
- Daemon receives response and routes as usual — no ntfy involved

Mobile interface options: minimal PWA served from the daemon, an iOS/Android Shortcut, or eventually a dedicated companion app.
