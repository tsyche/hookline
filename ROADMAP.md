# hookline Roadmap

> **tl;dr:** active work only — shipped entries live in
> [docs/ledger/ROADMAP_SHIPPED.md](docs/ledger/ROADMAP_SHIPPED.md).
> Multi-provider revival **Phases 0–4 shipped (2026-09-25)** as **v1.3.0** — `VERSION` is
> the source of truth, and the release workflow tags and publishes on the first main push
> that carries a `VERSION` change. Sections below are **phases** (the same scheme as
> Phases 0–4, house convention across projects), ordered next-up first: Phase 5
> reliability → Phase 6 onboarding → Phase 7 remote control + E2E.

> **Status: multi-provider revival (2026-09-25).** hookline was paused in maintenance mode
> (2026-06) when Claude Code shipped native remote/mobile approvals — but that covers
> **claude only**. The revival: the same phone-approval UX for every agent the `ai` alias can
> launch (claude · codex · grok · opencode · local custom providers) via a provider registry +
> adapter architecture. See the archived [multi-provider plan](~/.claude/plans/archive/hookline-multi-provider.md)
> for decisions, phases, and gates. Shipped phases are archived in the
> [shipped ledger](docs/ledger/ROADMAP_SHIPPED.md).
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

> **Backlog status:** Phase 4 (docs/wording sweep) landed 2026-09-25 — the old post-v1.2
> backlog has been re-triaged into Phases 5–6 under the multi-provider architecture.

## Goals

hookline should be installable and usable by anyone in under 5 minutes with nothing but a Mac, a phone, and an ntfy account. Every feature beyond that is an opt-in upgrade — not a requirement.

**Notification transport tiers (all first-class, user's choice):**
- **ntfy.sh public** — zero friction, works immediately, free; rate limits only a concern for very heavy use
- **Self-hosted ntfy** — full control, no rate limits, ~$5/mo VPS or existing server; recommended for daily drivers
- **Direct / relay-free** — Tailscale or VPN; no third-party services at all; advanced but genuinely accessible via the setup wizard
- **Pluggable backends** — Gotify, Telegram, Pushover, or custom; for users who already have preferred infrastructure

The setup wizard is what makes all tiers accessible. It should ask the right questions, explain tradeoffs plainly, and handle configuration — no manual file editing required.

## Recommended Next 3

1. **Push and confirm v1.3.0** — proves the release pipeline end-to-end (tag + generated notes on the `VERSION` bump); 6 commits are queued (~0.5h)
2. **`hookline doctor`** — turns "why didn't I get notified?" into one self-explaining command (~1–2h)
3. **Daemon health watchdog** — closes the known silent-degradation failure mode that already cost daily-driver notifications (~2–3h)

## Phase 5 — Reliability & self-healing (next)

1. **`hookline doctor` — diagnose & self-heal** (~1–2h)
   - One command that checks the whole chain and fixes what it can: daemon liveness (real socket ping, not just process presence), resolved `python3`/`tmux` paths, launchd registration, stale socket files, ntfy reachability, topic subscription reminder
   - Auto-restarts a hung/dead daemon; flags an asdf-shimmed `python3` that would break the hook
   - Motivated by a multi-hour debugging session where a hung daemon + asdf-broken `python3` silently dropped notifications and `hookline status` gave a misleading "NOT running"
   - Quick win; turns "why didn't I get notified?" into a single self-explaining command

2. **Daemon health watchdog** (~2–3h)
   - `KeepAlive` only restarts the daemon if it *exits*; a hung-but-alive process (observed after SSE 502 storms / system sleep, where `urllib` freezes despite its timeout) goes undetected for days
   - The hook already falls back to legacy polling when the daemon is unresponsive (notifications still fire), but the instant-SSE path stays degraded until a manual restart
   - Daemon touches a heartbeat timestamp each loop; a lightweight checker (separate launchd `StartInterval` job, or the hook itself) restarts the daemon if the heartbeat is stale. Also harden the SSE thread against silent `urllib` hangs (socket-level read timeout, or a maintained SSE client)
   - Promoted from the medium-term list after silent notification loss bit the daily driver

3. **Daemon unit tests** (~2–3h)
   - The Python daemon has zero automated coverage today — only the shell hook has golden tests, so registry/routing regressions ship undetected
   - stdlib `unittest` (no new deps) covering session registry mapping, response-file routing, tmux vs response-only paths, heartbeat staleness
   - Acceptance: a new `test-daemon` recipe runs in CI alongside `lint`, `golden`, and `check-docs`

## Phase 6 — Onboarding & contributors

1. **Setup wizard** (~2–3h)
   - `hookline setup` replaces manual config editing with a guided walkthrough anyone can follow
   - Asks: which transport? ntfy.sh public (default, zero config) → self-hosted ntfy → direct/Tailscale (daemon HTTP server)
   - For ntfy.sh: generate or enter topic, print QR code for phone subscription (requires `qrencode`)
   - For self-hosted ntfy: prompt for server URL + auth credentials; output a ready-to-use `docker-compose.yml`
   - Detects whether tmux is installed and active; recommends it for full multi-session support; offers `brew install tmux` if missing
   - If not using tmux, warns that keystroke injection only works reliably in a single terminal window — concurrent Claude sessions in separate tabs/splits won't both get focus-independent injection
   - All paths end with a live test notification so user knows it works before they walk away
   - Reruns cleanly to switch transports later
   - 🧑 needs-human: QR scan, phone subscription, and the live test-notification check happen on the device

2. **Pattern management CLI** (~2–3h)
   - `hookline patterns` — list current allowlist
   - `hookline remove-pattern <pattern>` — remove without hand-editing JSON
   - `hookline clear-patterns` — wipe project allowlist

3. **CONTRIBUTING.md** (~1–2h)
   - How to add a notification backend, how to add a provider adapter, how to test the hook locally (`just lint && just golden && just check-docs`), PR process
   - CI half of the original item is done: lint + golden + check-docs run on push/PR; Dependabot grouped monthly for `github-actions`

4. **In-repo git hooks** (~1h)
   - The `check-docs` pre-commit hook currently runs from machine-local `~/.git-hooks` via a global `core.hooksPath` — contributors (and any fresh clone) never get it
   - Vendor `.githooks/` in the repo plus a `hooks` recipe (and a CONTRIBUTING line); CI already gates the same checks, this closes the local-feedback gap

5. **CHANGELOG.md** (~1h)
   - Releases now publish generated notes automatically; a tracked CHANGELOG aggregates them per version so the repo shows release history without opening GitHub
   - Pulled forward from the old Future list now that release automation exists

## Phase 7 — Remote control + E2E

Feasibility assessed 2026-09-25 — all hard pieces already proven in Phases 0–4.

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
- [ ] **Generic provider naming in app-facing text** — setup/docs/status copy must never
  name private local providers (use "local" / "custom"); concrete ids stay in untracked
  config. Applied to README/ROADMAP/ledger 2026-09-25; verify future setup-wizard strings
  and audit tracked agent docs (`AGENTS.md`/`CLAUDE.md`) for stragglers.

## Phase 8 — Medium-term

- **Multi-session support (tmux)** — already works; each session registers its own `tmux_pane_id` and daemon injects to the correct pane directly
- **Multi-session support (bare terminals)** — per-terminal plumbing to capture a stable window/tab/pane identifier at session registration time and target it precisely at injection time; iTerm2 (AppleScript session ID), WezTerm (`wezterm cli --pane-id`), Terminal.app (window/tab index, fragile); ~2–3h per terminal emulator
- **Snooze mode** — "I'm at my desk for 60 min, skip phone notifications" toggle via `hookline snooze 60` or a phone button; sets a lock file the background process checks
- **Per-project config** — `.hookline` file at project root to override grace period, add project-specific safe patterns, set notification priority; loaded in addition to `~/.config/hookline/config`
- **Idle-aware grace period** — detect system idle time; skip grace period and notify immediately when machine has been idle
- **Companion app — one-tap deep link to the right session** — a small Android companion app that registers a custom URL scheme (e.g. `hookline://connect?host=mac&session=hookline`). hookline embeds the connect command (including the exact tmux session for the project that fired) as a `view`-action button on the notification; tapping it opens the app, which fires Termux's `RUN_COMMAND` intent with the *typed* extras Termux needs (boolean `RUN_COMMAND_BACKGROUND=false`, `String[]` arguments) — the thing a bare `ssh://` link or a string-only ntfy broadcast can't do. Lands you directly in the correct session, no manual picker. Why a companion app and not config + ConnectBot/Tasker: Termux registers no URL scheme, and ntfy can only send string intent extras, so the only clean Android paths are (a) ConnectBot as an `ssh://` handler — separate app, bare shell, or (b) a Tasker/MacroDroid bridge — paid/fragile, terrible onboarding. A first-party app owns the whole bridge with zero third-party glue. **Endgame:** the same app can grow a persistent connection straight to the hookline daemon (see [Relay-free Design](#relay-free-design-tailscale--vpn-direct-mode)) — at which point it receives the approval request *and* launches the session in-process, dropping the ntfy dependency on the receive side entirely. (Tracked here after a manual-flow decision: today, a missed prompt just sends a plain "prompt expired" notification and you connect by hand — VPN → Termux → `mac` → pick session.)
  - 🧑 needs-human: Android build, signing, and on-device install
- **PostToolUse feedback notifications** — optional low-priority phone notification after a tool completes showing what changed (e.g., "Edit: modified 3 lines in src/app.ts")
- **Tool-aware notification priority** — writes to sensitive paths (`/etc`, repo root) get high-priority ntfy; `/tmp` writes get low priority

## Phase 9 — Future

- **Pluggable notification backends** — abstract the notify/poll layer behind a backend interface so hookline isn't ntfy-specific; ship adapters for Gotify, Telegram bot, and Pushover; community can add others without touching core
- **Direct mode via Tailscale / VPN** — zero relay dependency; the endpoint design (port `7676`, `/pending`, `/respond`) and mobile interface options (PWA, Shortcut, companion app) are specced in [Relay-free Design](#relay-free-design-tailscale--vpn-direct-mode)
- **hookline relay (self-hostable)** — minimal relay server (single binary or Docker image) as a fully independent ntfy replacement
- **Linux support** — replace `osascript` keystroke injection with `xdotool` / `ydotool`
- **Notification content control** — configurable truncation; redact sensitive path segments
- **Approval history** — queryable log of what was approved/denied, when, and from where (terminal vs. phone)
- **Always-deny patterns** — companion to allowlist for commands that should always be blocked
- **Time-based rules** — configurable schedule (e.g. notify immediately after 6pm)

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
