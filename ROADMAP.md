# hookline Roadmap

> **tl;dr:** active work only — shipped entries live in
> [docs/ledger/ROADMAP_SHIPPED.md](docs/ledger/ROADMAP_SHIPPED.md).
> Multi-provider revival **Phases 0–4 shipped (2026-09-25)** as **v1.3.0** — `VERSION` is
> the source of truth, and the release workflow tags and publishes on the first main push
> that carries a `VERSION` change. Sections below are **phases** (the same scheme as
> Phases 0–4, house convention across projects), ordered next-up first: Phase 6
> onboarding → Phase 7 remote control + E2E (Phases 0–5 shipped).

> **Status: multi-provider revival (2026-09-25).** hookline was paused in maintenance mode
> (2026-06) when Claude Code shipped native remote/mobile approvals — but that covers
> **claude only**. The revival: the same phone-approval UX for every agent the `ai` alias can
> launch (claude · codex · opencode · local custom providers — grok a potential later addition)
> via a provider registry +
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
> **v1.4.0 tagged 2026-09-26** — Phase 5 reliability fully shipped (doctor, watchdog,
> daemon tests, release smoke check + target check, install/uninstall tests,
> heartbeat ages in status, log rotation / quiet SSE).
> **v1.5.0 tagged 2026-09-27** — codex adapter live (interim `PermissionRequest` Flow A),
> response-file hardening (`mktemp` + `0600`), codex MCP matcher, `just changelog-promote`,
> grok seam spike confirmed. Archived in the [shipped ledger](docs/ledger/ROADMAP_SHIPPED.md).

## Goals

hookline should be installable and usable by anyone in under 5 minutes with nothing but a Mac, a phone, and an ntfy account. Every feature beyond that is an opt-in upgrade — not a requirement.

**Notification transport tiers (all first-class, user's choice):**
- **ntfy.sh public** — zero friction, works immediately, free; rate limits only a concern for very heavy use
- **Self-hosted ntfy** — full control, no rate limits, ~$5/mo VPS or existing server; recommended for daily drivers
- **Direct / relay-free** — Tailscale or VPN; no third-party services at all; advanced but genuinely accessible via the setup wizard
- **Pluggable backends** — Gotify, Telegram, Pushover, or custom; for users who already have preferred infrastructure

The setup wizard is what makes all tiers accessible. It should ask the right questions, explain tradeoffs plainly, and handle configuration — no manual file editing required.

## Recommended Next 3

1. **Pattern management CLI** (~2–3h) — `hookline patterns` / `remove-pattern` / `clear-patterns` — committed, pending release
2. **CONTRIBUTING.md** (~1–2h) — adapters, backend, testing, PR process — committed, pending release
3. **In-repo git hooks** (~1h) — vendored `.githooks/` + `just hooks` — committed, pending release

> Previous recommended 3 (`check-gates`, opencode plugin tests, setup wizard) all shipped
> 2026-09-28 — see the [shipped ledger](docs/ledger/ROADMAP_SHIPPED.md).

## Phase 5 — Reliability & self-healing (complete)

> **Phase 5 shipped 2026-09-26** — `hookline doctor`, heartbeat watchdog, daemon
> unit tests, release smoke check (incl. target-commit check), install/uninstall
> sandbox tests, heartbeat ages in `status`, log rotation + quiet SSE reconnects.
> All entries preserved in the [shipped ledger](docs/ledger/ROADMAP_SHIPPED.md).

## Phase 6 — Onboarding & contributors (next)

1. **Pattern management CLI** (~2–3h) — committed, pending release
   - `hookline patterns` — list current allowlist (project + global scopes, non-consulted entries flagged)
   - `hookline remove-pattern [--global] <pattern>` — remove without hand-editing JSON (bare patterns wrapped in `Bash(...)`; atomic edit, mode preserved)
   - `hookline clear-patterns [--global]` — wipe project allowlist (global only with `--global`)
   - covered by `just patterns-test` (15 sandboxed cases, in `check-gates`)

2. **CONTRIBUTING.md** (~1–2h) — committed, pending release
   - How to add a notification backend, how to add a provider adapter, how to test the hook locally (`just lint && just golden && just check-docs`), PR process
   - CI half of the original item is done: lint + golden + check-docs run on push/PR; Dependabot grouped monthly for `github-actions`

3. **In-repo git hooks** (~1h) — committed, pending release
   - The `check-docs` pre-commit hook previously ran from machine-local `~/.git-hooks` via a global `core.hooksPath` — contributors (and any fresh clone) never got it
   - Shipped: vendored `.githooks/` (pre-commit = doc sync + `check-docs`, pre-push = `check-gates`) enabled via `just hooks`, documented in CONTRIBUTING; CI already gates the same checks

4. **grok adapter** (~3–4h) — seam CONFIRMED by spike (grok 1.0.41, archived in the
   [shipped ledger](docs/ledger/ROADMAP_SHIPPED.md)); not approved/built
   - Claude-compatible `PreToolUse` hooks in `~/.grok/hooks/*.json` (always-trusted), stdout
     decisions `allow|deny|ask|defer`; `ask` forces grok's prompt — the Flow A seam without
     codex's decline trick
   - Watch-outs: set hook `timeout` ≥ grace period (default 5s); approval-menu key profile unverified

5. **Question-dialog phone flow (opencode + claude/blackbox)** — committed `ed47d64` 2026-09-28, pending release
   - Gap closed: plugin hooks `question.asked`/`question.v2.asked` (spawns the hook) and
     `question.replied`/`rejected` (local-answer counter) — question dialogs get the same
     20s grace + phone notification as permission prompts; claude AskUserQuestion rides the
     same `build_question_message` builder (moved to core.sh) for identical body/buttons
   - Tap-to-answer: a single single-select question with 1–3 options gets its options as ntfy
     buttons → reply bridge → `question.reply` (v2 SDK client built over the injected v1
     client's transport — v1 has no `question` API and plain TCP to serverUrl is refused);
     claude answers inject the option number (daemon tmux send-keys, osascript otherwise);
     multi-select/stacked stay notify-only with the full question in the body
   - Typed replies: single-select questions ship their label list in the notify payload —
     replying with a number (`4`) or letter (`D`) on the bare topic resolves to
     `answer|<label>` (second bare-topic SSE listener); works for any option count past
     ntfy's 3-button cap, which also suppresses the default trio via `no_actions`
   - Word replies: `retry`/`deny` anywhere (`allow` for permissions); invalid replies push
     a correction notification with Retry/Deny buttons instead of silence
   - Extended window: watcher survives the phone timeout for `HOOKLINE_EXTENDED_WAIT`
     (default 3600s, checks every 180s) so late answers and `retry` still land; expiry
     cancels the pending entry
   - Tests: 10 new golden cases (37 total) + 19 new daemon tests (49 total)

6. **One-line install** (~1–2h)
   - README install is `git clone` + `just install`; a `curl -fsSL … | bash` path from a pinned
     GitHub release shortens the 5-minute install goal (release tarball or raw-GitHub fetch —
     `install.sh` today assumes repo-relative files)
   - Acceptance: fresh machine install with no git checkout of the repo

7. **Version / upgrade check** (~0.5–1h)
    - `hookline status` (and/or `doctor`) flags when the latest GitHub release tag is newer than
      the installed `VERSION` — release-smoke already fetches the latest tag, reuse that
    - Acceptance: outdated install reports the newer tag; up-to-date install stays quiet

8. **Internal link check** (~0.5h)
    - Extend `check-docs` to verify relative markdown links (ROADMAP → ledger, README → ROADMAP, …)
      so cross-doc references can't rot silently
    - Acceptance: a deliberately broken relative link fails `just check-docs`

9. **Long question lists — chunked/compressed bodies** (~1–2h)
    - Today the notification body truncates at 1500 chars, so a question with a long option
      list (or verbose descriptions) can lose options at the tail — typing still resolves
      any number, but the reader can't see what they're picking
    - Route A (cheap): compress rendering once over budget — drop descriptions, shorten
      labels, keep every numbered option visible; Route B: split the body across two ntfy
      messages (same question/req — typing `17` works from either)
    - Acceptance: a 30-option question with descriptions arrives fully visible and answerable
      by number

10. **`context` keyword — side-thread assessed summary** (~2–4h)
    - Type `context` while a question/permission is pending → a short assessed summary of
      where the conversation stands (not just raw lines) arrives as a new notification; the
      original prompt stays pending and is answered afterwards as usual
    - opencode: plugin-side one-shot side session over the in-process SDK client (list
      messages → prompt for summary → notify); claude/codex: headless CLI call
      (`claude -p` / `codex exec`) fed the transcript tail; fallback to raw tail when the
      model call fails or times out
    - Acceptance: `context` during a pending prompt returns a ≤10-line summary and the
      original prompt is still answerable by button/typed reply

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
