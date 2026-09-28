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
