# hookline — Shipped Roadmap Ledger

**TL;DR:** completed roadmap entries live in `docs/ledger/` (this file); active work stays in
`ROADMAP.md` at the repo root. Provider names here are generic — private local provider ids
live only in untracked config (`~/.config/hookline/config`).

## Index

| Era | Shipped | Notes |
|---|---|---|
| v1.1 | 2026-06 | first stable: hook intercept, ntfy buttons, injection, safe-prefixes |
| v1.2 core | 2026-06 | daemon + SSE, status/topic commands, multi-terminal injection, zombie prevention |
| v1.3.0 | 2026-09-25 | first tagged release; multi-provider revival phases 0–4 — registry + adapter split, local custom provider, opencode plugin adapter, graybox install with real phone-tap gates, docs sweep |
| Phase 5 | 2026-09-26 | reliability: `hookline doctor`, heartbeat + launchd watchdog, daemon unit tests |
| Release smoke | 2026-09-26 | assert latest GitHub release tag == `VERSION`, gated in CI right after every release |
| Phase 5b | 2026-09-26 | install/uninstall sandbox tests, heartbeat ages in `status`, log rotation + quiet SSE, smoke target-commit check |
| v1.4.0 | 2026-09-26 | tagged release covering the Phase 5 / 5b rows above (doctor, watchdog, tests, roadmap phase rework) |
| CHANGELOG | 2026-09-27 | Keep-a-Changelog file created, backfilled from v1.3.0 / v1.4.0 tags, `[Unreleased]` for pending work |
| v1.5.0 | 2026-09-27 | tagged release covering the Phase 6 rows below (codex adapter, response-file hardening, MCP matcher, changelog-promote, grok spike) |
| v1.6.0 | 2026-09-29 | question-dialog phone flow (typed/word replies, extended window), setup wizard, `just check-gates`, opencode plugin tests |
| v1.7.0 | 2026-09-29 | pattern management CLI, CONTRIBUTING.md, in-repo `.githooks/` + `just hooks` |
| Phase 6 b3 | 2026-09-29 | unreleased: question-body compression, one-line install, version check, grok adapter, bare-terminal multi-session targeting |
| Snooze | 2026-09-30 | unreleased: mute window (CLI + typed reply), watcher/daemon send guards |

## v1.1 — Stable (archived)

- [x] PreToolUse hook intercepts Bash, Edit, Write, NotebookEdit, AskUserQuestion
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

## v1.2 — shipped core (archived)

- [x] **ntfy Basic Auth** — `HOOKLINE_NTFY_USERNAME` / `HOOKLINE_NTFY_PASSWORD` wired into all curl calls
- [x] **`hookline status` command** — config, hook registration, daemon status, connectivity ping, last 10 log lines
- [x] **hookline daemon** — persistent Python daemon with SSE connection for instant phone response (no polling delay); session registry maps session IDs to TTY/terminal/tmux pane; response file IPC keeps keystroke injection in the hook's process tree (no extra macOS accessibility permissions); graceful fallback to inline polling when daemon is down
- [x] **Multi-terminal injection** — iTerm2, Terminal.app, WezTerm via AppleScript; tmux via `send-keys` (focus-independent); frontmost-app fallback for others
- [x] **Zombie prevention** — per-session lock file (parent writes `$!`), conditional EXIT trap, max retry cap, global ntfy throttle
- [x] **`hookline topic` command** — `hookline topic` shows the current topic; `hookline topic <name>` validates the name, rewrites `HOOKLINE_TOPIC` in config, and restarts the daemon in one step (avoids manual config editing when switching topics after an ntfy ban)
- [x] **AskUserQuestion hook** — warning notification sent with first-option-or-dismiss behavior; `defer` keeps Claude's own picker visible while Allow injects `1`+Enter and Deny injects Escape

## v1.3.0 — Multi-provider revival, phases 0–4 (archived 2026-09-25)

Plan: `~/.claude/plans/archive/hookline-multi-provider.md`.

- **Phase 0** — roadmap flipped to multi-provider revival; CI runner bumped
- **Phase 1** — provider-neutral core split from adapters; provider registry gate
  (`HOOKLINE_PROVIDERS` in untracked config; unlisted providers exit silently); adapters for
  claude and a local custom claude-profile provider; per-provider settings registration;
  golden-test harness + gate tests; agent docs updated
- **Phase 2** — opencode adapter: auto-loaded plugin answers permission prompts in-process
  (unix-socket bridge, `ADAPTER_RESPONSE_ONLY` daemon path); install/uninstall/status/plugin
  registration; **gate passed with a real phone tap** (2026-09-25, allow → plugin replied →
  gate command ran)
- **Phase 3** — graybox install on the local machine: launchd daemon, both settings
  registrations, plugin, topic, phone subscription all green; fixed tmux socket injection
  (registered socket path; launchd lacks `TMUX_TMPDIR`) and fake local-answer detection
  (progress counter counts only real transcript entries); **gates passed with real phone
  taps** — local custom provider (tmux allow → prompt resolved → file written) and opencode
  (allow → plugin reply → gate command ran)
- **Phase 4** — wording sweep: README made provider-neutral (tl;dr, Providers section,
  adding-an-adapter contract, `HOOKLINE_PROVIDERS` docs, OpenCode install/terminal rows);
  `just lint` green

## Post-v1.3.0 — release pipeline confirmed (archived 2026-09-26)

- [x] 2026-09-26 — **Push and confirm v1.3.0** — proves the release pipeline end-to-end
  (tag + generated notes on the `VERSION` bump); 6 commits were queued (~0.5h).
  Verified: release workflow run 36214305762 published `v1.3.0` automatically; a
  follow-up docs-only push re-ran CI green without retriggering a release.

## Phase 5 — Reliability & self-healing (shipped 2026-09-26)

1. **`hookline doctor` — diagnose & self-heal** (~1–2h)
   - One command that checks the whole chain and fixes what it can: daemon liveness (real socket ping, not just process presence), resolved `python3`/`tmux` paths, launchd registration, stale socket files, ntfy reachability, topic subscription reminder
   - Auto-restarts a hung/dead daemon; flags an asdf-shimmed `python3` that would break the hook
   - Motivated by a multi-hour debugging session where a hung daemon + asdf-broken `python3` silently dropped notifications and `hookline status` gave a misleading "NOT running"
   - Quick win; turns "why didn't I get notified?" into a single self-explaining command
   - Acceptance: a sandboxed regression recipe (same shape as `scripts/hook-golden.sh`) runs in CI alongside `lint`, `golden`, `check-docs`

2. **Daemon health watchdog** (~2–3h)
   - `KeepAlive` only restarts the daemon if it *exits*; a hung-but-alive process (observed after SSE 502 storms / system sleep, where `urllib` freezes despite its timeout) goes undetected for days
   - The hook already falls back to legacy polling when the daemon is unresponsive (notifications still fire), but the instant-SSE path stays degraded until a manual restart
   - Daemon touches a heartbeat timestamp each loop; a lightweight checker (separate launchd `StartInterval` job, or the hook itself) restarts the daemon if the heartbeat is stale. Also harden the SSE thread against silent `urllib` hangs (socket-level read timeout, or a maintained SSE client)
   - Promoted from the medium-term list after silent notification loss bit the daily driver
   - Acceptance: heartbeat staleness covered by the daemon unit-test recipe (Phase 5 item 3), so watchdog lands with tests, not after

3. **Daemon unit tests** (~2–3h)
   - The Python daemon has zero automated coverage today — only the shell hook has golden tests, so registry/routing regressions ship undetected
   - stdlib `unittest` (no new deps) covering session registry mapping, response-file routing, tmux vs response-only paths, heartbeat staleness
   - Acceptance: a new `test-daemon` recipe runs in CI alongside `lint`, `golden`, and `check-docs`

### 2026-09-26 — Release smoke check (shipped)

1. **Release smoke check** (~0.5h)
   - Post-push script asserting the latest GitHub release tag matches `VERSION`
   - Catches a silent release-pipeline regression (the pipeline is now the only release path)

## Phase 5 (rest) — Reliability quick wins (shipped 2026-09-26)

1. **Install/uninstall sandbox tests** (~1–2h)
   - `install.sh` / `uninstall.sh` were only graybox-tested by hand in Phase 3
   - Recipe runs both in a temp `HOME` + fake `~/.claude` and asserts settings-JSON
     registration pairs invert exactly, plugin file appears/disappears

2. **Heartbeat ages in `hookline status`** (~0.5h)
   - Doctor shows heartbeat/SSE age; the everyday `status` command doesn't — same
     data, one field per line

3. **Daemon log rotation / quieter SSE reconnects** (~0.5h)
   - `daemon.log` grows unbounded; with the 300s SSE read timeout a healthy idle
     connection now reconnects (and logs) every ~5 min — cap size or log only
     state changes

4. **Release smoke: target commit check** (~0.3h)
   - Extend `scripts/release-smoke.sh` to assert the release's `targetCommitish`
     equals the checked-out main HEAD — tag==VERSION alone misses a release
     tagging the wrong commit

## Phase 6 item — CHANGELOG.md (shipped 2026-09-27)

6. **CHANGELOG.md** (~1h)
   - Releases now publish generated notes automatically; a tracked CHANGELOG aggregates them per version so the repo shows release history without opening GitHub
   - Pulled forward from the old Future list now that release automation exists

## Phase 6 — codex adapter + hardening (shipped 2026-09-27, v1.5.0)

6. **codex adapter (interim hack)** — committed `689f939` 2026-09-27, released in v1.5.0
   - Flow A over codex's `PermissionRequest` hook: empty stdout declines → codex's own approval
     menu shows; phone answer arrives as keystrokes (Enter approves — option 1 preselected,
     Esc cancels; both verified against codex 0.157.1 in tmux)
   - Injection follows the claude pattern: watcher injects into its own `$TMUX_PANE` via
     `tmux send-keys` inside tmux (pane-exact, works detached — daemon keys stay
     claude-hardcoded, hence response-only `ADAPTER_RESPONSE_ONLY=1`), frontmost-app
     osascript on bare terminals (claude's non-tmux path)
   - Rollout JSONL growth = local-answer signal (raw count — the rollout doesn't grow while
     the menu sits open)
   - Registration merges a `PermissionRequest` entry into `~/.codex/hooks.json` (foreign hooks
     preserved, exact inverse on uninstall, round-trip tested); off until `codex` joins
     `HOOKLINE_PROVIDERS`; one-time `/hooks` trust review (doctor reports registered + trusted)
   - Live E2E proven with real ntfy taps: allow → file created, deny → menu canceled,
     retry → `-r1` resend → approve, stale/cancelled req ignored
   - Interim by design: rip out when codex ships a real remote-approval integration; safe
     prefixes emit a foreground `allow` so read-only commands skip the menu entirely
   - Tests: 6 new golden cases (24 total) + install round-trip asserts (45); all 8 gates green

7. **Response-file hardening** — implemented 2026-09-27, released in v1.5.0
   - Response files use predictable `/tmp` names — any local process could write an allow decision; switch to `mktemp` + `600` perms
   - Ranks in the Recommended Next 3: security debt before wider distribution
   - Acceptance: no predictable response path remains in core; golden/install tests updated
   - Done: hook now `mktemp` + `0600` in private `$TMPDIR` (pid+random fallback); daemon recreates at `0600` on every retry round; daemon test asserts the mode

8. **codex MCP matcher coverage** — implemented 2026-09-27, released in v1.5.0
   - README documents `Bash` + `apply_patch` only; extend the `PermissionRequest` matcher to `mcp__*` tools so MCP approvals notify too
   - Acceptance: MCP tool request produces a phone notification and injects correctly
   - Done: matcher `Bash|apply_patch|mcp__.*`, golden `codex-mcp-ask` case, install-test matcher assert; E2E still on codex's own approval menu

9. **CHANGELOG release sync** — implemented 2026-09-27, released in v1.5.0
   - Automate promoting `[Unreleased]` → `## [x.y.z]` on a `VERSION` bump (release workflow step or just recipe) so the tracked CHANGELOG can't rot
   - Done: `just changelog-promote` (idempotent; promotes heading + link footer); CHANGELOG header documents the release hygiene step

10. **grok approval-seam spike** — done 2026-09-27: **seam CONFIRMED** (grok 1.0.41)
    - `~/.grok/hooks/*.json` global hooks are always trusted; Claude-compatible `PreToolUse` with stdin JSON (`toolName`/`toolInput` camelCase) and stdout decisions `allow|deny|ask|defer` (fail-open, regex matchers, `Bash`→`run_terminal_command` aliases)
    - `ask` forces grok's permission prompt even when policy would auto-approve — the Flow A seam exists without codex's decline trick
    - Watch-outs: default hook timeout is 5s (must set `timeout` ≥ grace period); approval-menu key profile (Enter/Esc?) unverified
    - Next: grok adapter (~3–4h: adapter + `~/.grok/hooks` registration + live E2E of prompt keys)

11. **`check-gates` recipe** — done 2026-09-28
    - `just check-gates` runs every gate CI runs (`lint`, `golden`, `test-daemon`, `test-plugin`,
      `doctor-test`, `status-test`, `install-test`, `release-smoke-test`, `check-docs`); `ci.yml`
      is a single `just check-gates` call, so local and CI gate lists cannot drift
    - Acceptance met: recipe green locally, CI reduced to the one call

12. **opencode plugin tests** — done 2026-09-28
    - `tests/test_plugin.mjs` — 8 `node --test` cases with a fake SDK client and a fake hook
      script: spawn on `permission.asked`/`question.asked` (payload + reply-sock env captured
      from stdin/stdout), counter appends (`permission.replied`/`question.rejected`), bridge
      reply paths (permission / question reply / question-reject), dispose closes the socket
    - Pitfalls encoded as comments: reply socket needs a short `/tmp` unix path (macOS
      `sun_path` ≤104 — long `/var/folders` sandbox dirs fail `listen EINVAL` and the plugin's
      listen promise now rejects instead of hanging); counter lines are *empty* lines counted
      by newline (the adapter's `wc -l` signal), not non-empty entries; capture waits for the
      final line to avoid racing the fake hook's writes
    - `package.json` adds `{"type":"module"}` so the plugin imports as ESM; `just test-plugin`
      joins `check-gates`

13. **Setup wizard** — done 2026-09-28
    - `hookline setup`: transport tiers (ntfy.sh default with leftover-auth cleanup ·
      self-hosted prompt for URL/auth + `binwiederhier/ntfy` `docker-compose.yml` written to
      `~/.config/hookline/docker-compose.yml` · direct/Tailscale shown as not-yet-available),
      topic keep/generate/validate (`[-_A-Za-z0-9]`), subscribe-URL QR via `qrencode` (URL
      always printed), tmux detect with `brew install` offer + no-tmux injection warning,
      live test notification (exit 1 when the publish fails), idempotent `set_config`,
      daemon restart only on real config change
    - `install.sh` now preserves existing config (topic, self-hosted server/auth, extended
      window) instead of overwriting — reinstalls keep wizard-set values

## Phase 6 (batch 2) — Onboarding & contributors (shipped 2026-09-29, v1.6.0 / v1.7.0)

14. **Question-dialog phone flow (opencode + claude/local custom)** — committed `ed47d64` 2026-09-28, released v1.6.0 2026-09-29
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

15. **Pattern management CLI** — done 2026-09-29, released v1.7.0
    - `hookline patterns` lists `permissions.allow[]` from the project
      (`.claude/settings.local.json`) and global (`~/.claude/settings.json`) settings files,
      flagging non-`Bash(...)` entries the hook does not consult
    - `hookline remove-pattern [--global] <pattern>` — bare patterns wrapped in `Bash(...)`;
      `hookline clear-patterns [--global]` wipes the allowlist while preserving sibling keys;
      edits are atomic (temp file beside the target), preserve file mode, refuse invalid JSON,
      drop `permissions.allow`/`permissions` when they end up empty
    - `scripts/patterns-test.sh` — 15 sandboxed cases, wired into `check-gates`
    - CI caught a GNU/BSD `stat` divergence on the first run (`stat -f` = filesystem status on
      GNU, so mode preservation silently no-op'd → files became `0600`); fixed by trying
      `stat -c` first and treating a failed `chmod` as fatal — the test that caught it also
      guards the fix

16. **CONTRIBUTING.md** — done 2026-09-29, released v1.7.0
    - Local testing workflow + test-layer map, how to add a provider adapter (interface
      defers to the `hooks/core.sh` contract block; registration shapes: settings JSON /
      hooks.json merge / plugin copy, each with an inverse in `uninstall.sh`),
      how to add a notification backend (ntfy legs to replace, unix-socket JSON contract to
      keep), PR process (Conventional Commits, `check-gates`, changelog-promote on bump);
      README links it

17. **In-repo git hooks** — done 2026-09-29, released v1.7.0
    - Vendored `.githooks/` (pre-commit = AGENTS→CLAUDE sync + `check-docs`; pre-push =
      `check-gates`) enabled by `just hooks` (repo-local `core.hooksPath`); both skip
      gracefully when `just`/the recipe is absent and accept `--no-verify`
    - Closes the local-feedback gap: the checks previously lived only in a machine-global
      `~/.git-hooks`, so fresh clones got nothing; CI runs the same recipe either way

18. **Generic provider naming audit** — done 2026-09-29 (Phase 7 item)
    - Setup-wizard strings, README, status/doctor copy, docs/, ledger verified clean;
      3 stragglers fixed in tracked docs (CHANGELOG 1.6.0 entry, CONTRIBUTING alias
      example, roadmap question-flow entry); code comments exempt — ids live in untracked
      config + the code that consumes them

## Phase 6 (batch 3) — question-body compression + grok adapter (shipped 2026-09-29, unreleased)

19. **Long question lists — chunked/compressed bodies** — done 2026-09-29 (unreleased)
    - Gap: the notification body truncated at 1500 chars, so a long option list (or verbose
      descriptions) lost options at the tail — typing still resolved any number, but the
      reader couldn't see what they were picking
    - Shipped Route A (the cheap route): over budget the body re-renders compressed —
      descriptions dropped, labels capped at 120 chars — and if that still overflows,
      `fit_question_body` (hooks/core.sh) equal-shares the option lines: headers capped at
      a third of the budget, every numbered line shares the remainder, too-long lines get
      "..." — all options always numbered and visible; the reply hint and the typed-reply
      label list are built from the raw payload, so answering never depends on the render
    - Route B (split across two ntfy messages) not needed — acceptance met without it
    - Acceptance met: a 30-option question with descriptions arrives fully visible and
      answerable by number (`scripts/hook-golden.sh` — 3 new notify-payload cases:
      compressed 30-opt keeps every option + drops descriptions, long-label equal-share
      fit stays ≤1500, short question keeps its descriptions; 40 golden cases total)

20. **grok adapter** — done 2026-09-29 (unreleased)
    - Contract probed live on grok 1.0.44 before building: the claude `hookSpecificOutput`
      decision shape is accepted verbatim (`ask` forces grok's permission card even when a
      claude-compat allow rule would run the call; defer leaves grok's own rules in charge),
      the registered matcher is tested against grok's native tool names (anchored
      alternation — `run_terminal_command`, `write`, `search_replace`, `ask_user_question`
      all observed firing; anchoring keeps MCP `server__tool` names out), global
      `~/.grok/hooks/*.json` handlers run with no trust step, and the `ask_user_question`
      payload is claude-shaped — so the shared question builder/buttons ride over unchanged
    - Permission-card key profile (probed): allow = the allow-once row's digit parsed off
      the pane screenshot — labels vary per prompt class ("Yes, proceed" / "Yes" /
      "allow once") and row order shifts with `remember_tool_approvals`, and the focused
      row defaults to always-approve, so Enter is never safe and a parse miss injects
      nothing; deny = Ctrl+C (Esc only parks focus); question answers = the option digit
      only (the card auto-advances between questions and auto-submits on the last)
    - Response-only like codex (`ADAPTER_RESPONSE_ONLY=1`): registers without a pane →
      response file → watcher-side `adapter_inject` (tmux send-keys into the hook's own
      pane, iTerm2 session-contents screenshot outside tmux); the daemon's tmux keys stay
      claude-specific — "1" would be grok's always-approve row
    - Registration merges `~/.grok/hooks/hookline.json` (foreign hooks preserved, inverse
      in uninstall.sh, `hookline status` section); allowlist source = the Claude settings
      files grok itself loads (`Bash(...)` patterns); local-answer signal = raw
      `updates.jsonl` line count (grows on turn resolution, idle while a card sits)
    - Verified: 19 new golden cases (59 total — stdout contract, notify payloads, progress
      counter, row-parser fixtures incl. a real boxed pane capture), install-test roundtrip
      (107 total), and a live tmux E2E: safe-prefix/allowlist defer, forced ask card, phone
      allow → digit → file, deny → Ctrl+C, question defer → `answer|<label>` → digit,
      local answer during grace → cancel with no notification

21. **One-line install** — done 2026-09-29 (unreleased), incl. the non-macOS fail-fast guard
    - `curl -fsSL … | bash` → tagged release tarball → `install.sh`; original entry:
      "Acceptance met: fresh machine install with no git checkout of the repo
      (`scripts/get-test.sh` — 12 offline cases)"

22. **Version / upgrade check** — done 2026-09-29 (unreleased)
    - `hookline status` flags when the latest GitHub release tag is newer than the
      installed `VERSION` (recorded by `install.sh`); original entry: "Acceptance met:
      outdated install reports the newer tag; endpoint-down stays quiet"

23. **Multi-session support (bare terminals)** — done 2026-09-29 (unreleased)
    - `focus_prompt_window` (hooks/core.sh) runs before every keystroke injection —
      iTerm2 selects the window/tab by `TERM_SESSION_ID` UUID (live-probed), WezTerm
      activates the pane via `wezterm cli activate-pane --pane-id`; Terminal.app /
      unknown terminals keep the frontmost fallback (no stable id — Window/tab index
      stays fragile, deliberately untouched); tmux already pane-exact. Watchers inject
      (both adapters), so the terminal env rides the hook process — no daemon changes.
      Tests: `scripts/focus-test.sh` (15 dry-run cases, in `check-gates`)

## Phase 8 item — snooze mode (shipped 2026-09-30, unreleased)

24. **Snooze mode** — done 2026-09-30 (unreleased)
    - Mute-window file `~/.local/share/hookline/snooze` (future unix epoch), checked
      before every phone push: the hook's background watcher skips the whole
      daemon/legacy notify handoff and just watches the transcript for a local answer
      (prompt stays at the terminal; expiry notices suppressed); the daemon's
      `send_ntfy` guards retries/feedback with a `force` bypass for confirmations
    - `hookline snooze [minutes|off|clear|0]` sets/clears/reports the window;
      `hookline status` gained a `── snooze` section
    - Phone side: typed `snooze` / `snooze <minutes>` / `unsnooze` from the ntfy app
      (one spaced form allowed in `TYPED_REPLY_RE`); the confirmation carries an
      Unsnooze button that routes through the response-topic handler; neither form
      ever resolves a pending prompt
    - Verified: `scripts/snooze-test.sh` 14 CLI cases (in `check-gates`), 2 golden
      cases (active window → no notify reaches the daemon; expired window → normal
      notify), 10 daemon unit tests (send guard, force bypass, reply/button routing,
      pending untouched)
