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
