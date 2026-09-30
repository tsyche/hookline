# Changelog

Notable changes per release. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

**Release hygiene:** run `just changelog-promote` when bumping `VERSION` so `[Unreleased]` lands in the new entry.

## [Unreleased]

### Added

- Typed-reply disambiguation — with 2+ prompts pending, a bare reply no longer gets dropped: it parks the attempt and pushes a picker notification listing each pending prompt (`1. [title] (question/permission)` lines, explicit force-send so a typed reply always gets feedback). Reply `1`–`N` picks the prompt — a parked word (`deny`/`retry`/`allow`) or queued option applies to it immediately; with no parked reply the pick stores (one reply per pick, 3-minute TTL, re-validated against what's still pending) and a note says what to send next. Single-prompt behavior is unchanged, and button taps (which carry `req_id`) never needed any of this. Tests: 7 new daemon unit cases (picker push, queue-then-pick, pick-then-option, pick-then-word, allow-on-picked-question, stale pick, out-of-range number)
- Alert metadata — every notification identifies itself at a glance: titles are now `[provider · session/project] ToolName` (prompt, expiry, and the daemon's derived notices all ride the same `notify_title`) and bodies open with a `project · branch · directory` header line before the command or question. The hook computes the header once, prepends it to every notification body (daemon notify, legacy direct path, expiry, question bodies — the question budget reserves room for it), and registers it with the session so invalid-reply corrections and `context` summaries prepend it too. `HOOKLINE_ALERT_HEADER=0` drops the body line only — the title tag stays (privacy). Tests: 3 golden metadata cases (claude title+header, opencode, header-off) + daemon unit coverage (register field, invalid-reply and context header)

## [1.8.0] - 2026-09-30

### Added

- `context` keyword — type `context` from the ntfy app while a prompt is pending and a separate notification arrives with an assessed ≤10-line summary of where the conversation stands (current task, what just happened, what the pending prompt asks); the pending prompt, its options, and its response file stay untouched, so the original prompt is still answerable by button or typed reply. The hook's register payload gained `provider`/`transcript_path`/`cwd`; the daemon runs the provider's own headless CLI over the transcript tail (`claude -p`, `codex exec -s read-only` with the prompt on stdin, `grok -p`, `opencode run --pure`; opencode has no transcript file, so its tail comes from a read-only `opencode export`) with `HOOKLINE_CONTEXT_CHILD=1` — the entry guard consumes stdin and no-ops so the summarizer's own hooks can never start a second phone flow; any failure (no transcript, missing binary, timeout, non-zero, empty) falls back to the raw tail (last 10 lines). Sent with `force=True` (explicit request bypasses snooze), ANSI-stripped and budget-capped like question bodies, no buttons; `HOOKLINE_CONTEXT_TIMEOUT` (config, default 45s) bounds the model call. Tests: 12 daemon unit cases (`TestContextKeyword`) + 2 golden register-payload cases
- Linux Tier 1 (systemd) — `install.sh`/`get.sh`/`uninstall.sh`, the `hookline` CLI, and the watchdog now detect the init system (`HOOKLINE_INIT_SYSTEM` env override, else OSTYPE auto-detect): on Linux with systemd the installer writes `~/.config/systemd/user/{hookline-daemon.service,hookline-watchdog.service,hookline-watchdog.timer}` (a 60s user timer mirrors launchd's `StartInterval`), registers with `systemctl --user enable --now`, and probes the user bus before writing anything (fail-fast with the `loginctl enable-linger` fix) plus a linger note at the end; `hookline daemon start|stop`, doctor, and status use the platform's job files and calls (`enable --now` / `disable --now` / `is-enabled`), and the watchdog dispatches `launchctl`/`systemctl` the same way (enabled-but-dead unit restarts, deliberately disabled stands down). `HOOKLINE_CLI_DIR` overrides the CLI destination (tests use it to run non-sandbox registration off `/usr/local/bin`); tests pin the init system per case (`scripts/install-test.sh` 98 cases incl. systemd sandbox + stubbed non-sandbox round trip, `scripts/get-test.sh` 12, `scripts/doctor-test.sh` systemd layout, `tests/test_daemon.py` dispatch tests). Fresh-Ubuntu acceptance run still pending (ROADMAP Phase 8)
- Bare-terminal multi-session targeting — when the phone answers a prompt, hookline now focuses the exact session that asked before injecting keystrokes: iTerm2 selects the window/tab whose AppleScript session id matches `TERM_SESSION_ID` (prefix stripped — `w0t1p2:UUID` builds included), WezTerm runs `wezterm cli activate-pane --pane-id $WEZTERM_PANE`. Terminal.app and unknown terminals keep the frontmost fallback (no stable id exists); tmux unchanged (`send-keys` already pane-exact). New `focus_prompt_window` in `hooks/core.sh`, `HOOKLINE_FOCUS_DRY_RUN=1` for offline tests (`scripts/focus-test.sh`, 15 cases)
- `hookline status` version check — compares the installed version (recorded by `install.sh` as `~/.local/share/hookline/VERSION`) against the latest GitHub release tag and flags the upgrade; degrades quietly when the endpoint is unreachable, and `HOOKLINE_LATEST_RELEASE_URL` overrides the endpoint so tests stay offline
- One-line install — `curl -fsSL https://raw.githubusercontent.com/tsyche/hookline/main/get.sh | bash` resolves the latest GitHub release (or `HOOKLINE_VERSION`), downloads the tagged tarball to a temp dir, and runs its `install.sh`; the topic prompt re-attaches to the terminal via `/dev/tty`, and `HOOKLINE_TARBALL_BASE` lets tests run offline (`scripts/get-test.sh`, 12 cases)
- Grok support — a new adapter (`hooks/adapters/grok.sh`) rides grok's claude-compatible `PreToolUse` hooks: `install.sh` merges a `hookline.json` entry into `~/.grok/hooks/` (foreign hooks preserved, config untouched, no trust step; inverted by `uninstall.sh`; `hookline status` reports it). Permissions emit the claude decision shape — `ask` forces grok's permission card, safe prefixes and `Bash(...)` allowlist entries from the Claude settings grok itself loads defer silently; questions defer into grok's picker and reuse the shared question body/buttons. Phone answers inject from the hook-side watcher (response-only like codex, because the daemon's tmux keys are claude-specific — "1" would be grok's always-approve row): allow types the allow-once row's digit parsed off the pane screenshot (labels and order vary by prompt class), deny sends Ctrl+C (Esc only parks focus), a question answer types the option digit (auto-advances, auto-submits); an unreadable screen injects nothing. Local answers are detected from the `updates.jsonl` transcript. Matcher = anchored grok-native names (`run_terminal_command`/`write`/`search_replace`/`ask_user_question` + claude aliases). `scripts/hook-golden.sh` 19 new cases (59 total, incl. row-parser fixtures), `scripts/install-test.sh` roundtrip (107 total); live tmux E2E: forced card, phone allow→file, deny→Ctrl+C, question answer, local-answer grace cancel
- Snooze mode — mute phone notifications for N minutes without touching the terminal prompt: `hookline snooze [minutes|off|clear|0]` writes a future-epoch window file that every send path checks — the hook's background watcher skips the daemon/legacy notify handoff entirely (the prompt stays, the watcher keeps detecting a local answer, expiry notices are suppressed) and the daemon's `send_ntfy` guards retries/feedback (`force` lets snooze confirmations through); `hookline status` gained a `── snooze` section. From the ntfy app, typed `snooze` / `snooze <minutes>` / `unsnooze` flip the window (one spaced form allowed in the typed-reply regex) and the confirmation carries an **Unsnooze** button routed through the response-topic handler. Tests: `scripts/snooze-test.sh` (14 cases, in `check-gates`), 2 golden cases (active window → no notify reaches the daemon; expired window → normal notify), 10 daemon unit tests (send guard, force bypass, reply/button routing, pending prompt untouched)
- `hookline doctor` per-provider registration checks — the "Hook & registration" section now verifies every provider `status` reports: grok was the gap (registered file check against `~/.grok/hooks/hookline.json`, no trust step — it joins claude settings, the opencode plugin, and codex registered+trusted). `scripts/doctor-test.sh` gained the missing-provider matrix: claude/opencode/codex/grok unregistered → FAIL, codex untrusted → FAIL, and the healthy-install case now seeds all four providers green (10 total cases)

### Fixed

- long question lists lost their tail options — the notification body hard-truncated at 1500 chars, so a 30-option question could arrive with options cut off; over budget the body now re-renders compressed (descriptions dropped, labels capped at 120 chars) and if still too long `fit_question_body` equal-shares the option lines so every numbered option stays visible; the reply hint and typed-reply label list come from the raw payload, so answering never depended on the render (`scripts/hook-golden.sh` — 3 new cases, 40 total)
- installer aborts immediately on unsupported platforms — an unguarded `launchctl` hit `set -e` mid-install on Linux, leaving a partial install with no message; `install.sh` and `get.sh` now detect the init system up front (macOS → launchd, Linux with systemd → `systemd`, anything else → fail fast with a pointer to ROADMAP Phase 8) before writing anything; `HOOKLINE_SANDBOX=1` keeps sandboxed tests running on either platform
- topic prompt survives piped installs — `read` returning non-zero on EOF no longer killed `install.sh` under `set -e` before the topic could be generated

## [1.7.1] - 2026-09-29

### Fixed

- pattern edits preserve file mode on Linux — `stat -f` (BSD format) silently returned filesystem info on GNU coreutils, so mode restoration no-op'd and edited settings files fell back to `0600`; GNU `stat -c` is tried first and a failed `chmod` now aborts the edit (caught by `patterns-test` in CI on the v1.7.0 push)

### Changed

- ROADMAP: Phase 6 batch 2 (pattern CLI, CONTRIBUTING, git hooks, question flow) archived to the shipped ledger and re-triaged; Phase 7 provider-naming audit completed (3 doc stragglers fixed)
- CONTRIBUTING/CHANGELOG: provider-naming rule applied — no private local provider ids in app-facing docs

## [1.7.0] - 2026-09-29

### Added

- `hookline patterns` — list allowlist entries from the project (`.claude/settings.local.json`) and global (`~/.claude/settings.json`) settings files, flagging entries the hook does not consult; `hookline remove-pattern [--global] <pattern>` drops one entry (bare patterns are wrapped in `Bash(...)`) with not-found diagnostics; `hookline clear-patterns [--global]` wipes the allowlist while preserving sibling settings keys — edits are atomic (temp file beside the target), preserve file mode, and refuse invalid JSON
- `just patterns-test` — 15 sandboxed pattern-CLI cases wired into `check-gates`
- `CONTRIBUTING.md` — local testing (`just check-gates`), test-layer map, how to add a provider adapter (contract defers to `hooks/core.sh`), how to add a notification backend (ntfy legs to replace, socket contract to keep), PR process; README links it
- `.githooks/` + `just hooks` — vendored pre-commit (AGENTS→CLAUDE sync + `check-docs`) and pre-push (`check-gates`) so fresh clones get the local feedback loop that previously lived only in a machine-global `core.hooksPath`; both skip when `just`/the recipe is absent and accept `--no-verify`

## [1.6.0] - 2026-09-28

### Added

- `hookline setup` — guided setup wizard: transport choice (ntfy.sh public default · self-hosted URL/auth + ready `docker-compose.yml` · direct/Tailscale shown as not-yet-available), topic keep/generate/validate, subscribe QR via `qrencode` (URL always printed), tmux detect with install offer and no-tmux injection warning, and a live test notification on every path; idempotent config writes, daemon restart only when config actually changed
- `just check-gates` — one command runs every gate CI runs; `ci.yml` now calls the recipe instead of listing steps, so local and CI gate lists can't drift
- `just test-plugin` + `tests/test_plugin.mjs` — 8 `node --test` cases for the opencode plugin (spawn payload/env plumbing, local-answer counter, bridge reply paths, dispose), the last adapter layer with zero coverage
- opencode question-dialog notifications: `question.asked` (and `question.v2.asked`) now ride the same grace-period phone flow as permissions; single single-select questions with 1–3 options answer from ntfy buttons via `client.question.reply`, everything else is notify-only (ntfy's 3-button cap); `question.replied`/`rejected` feed the local-answer signal
- typed option replies: single-select questions ship their full label list in the notify payload and the body prompts for it — reply with an option's number (`4`) or letter (`D`) on the response topic to answer, which makes 4+ option questions answerable from the phone despite the 3-button cap
- claude + local custom provider AskUserQuestion parity: question dialogs ride the shared `build_question_message` body/buttons/typed-reply flow; the daemon answers via tmux option-number injection (bare terminals get osascript keystrokes through the response file)
- word replies: type `retry` or `deny` in the ntfy channel anywhere a button would work (`allow` for permission prompts) — no tapping needed
- invalid-reply feedback: a reply that resolves to no option (typed word, out-of-range number) pushes a correction notification with the valid replies and Retry/Deny buttons; the question stays pending
- extended window: after the phone timeout the watcher stays alive for `HOOKLINE_EXTENDED_WAIT` seconds (default 3600, checks every `HOOKLINE_EXTENDED_INTERVAL`, default 180) so late answers, button taps, and typed `retry` still land; the expiry notice says how long. Legacy (no-daemon) path unchanged

### Fixed

- reinstall no longer overwrites `~/.config/hookline/config` — topic, self-hosted server/auth, and extended-window settings set by `hookline setup` survive `bash install.sh`
- opencode plugin's reply-socket listen error now rejects instead of resolving never (an unreachable bind path previously hung plugin load silently)
- opencode question replies use a v2 SDK client built over the injected client's own transport (in-process fetch); the injected client is the v1 surface with no `question` API, so replies previously died with `TypeError: undefined is not an object`
- notify-only notifications (4+ option, multi-select, stacked questions) no longer arrive with the default Allow/Deny/Retry buttons — an explicit `no_actions` flag distinguishes them from permissions, which keep the trio

## [1.5.0] - 2026-09-27

### Added

- Codex adapter: `PermissionRequest` Flow A hook — declines so codex's own approval menu shows, phone answer injects Enter/Esc into the owning tmux pane (frontmost window outside tmux); registration merges `~/.codex/hooks.json` with one-time `/hooks` trust review
- Codex MCP matcher coverage — `mcp__*` tools ride the same decline → menu → phone-answer flow
- `just changelog-promote` — promotes `[Unreleased]` to the current `VERSION` entry (idempotent; run right after bumping `VERSION`, in the same commit)
- Phase 5 test-gap completion: sandboxed install round-trip, status report, and release smoke-check test suites
- README codex notes (trust, approval preconditions, scope, key injection), claude native-approvals note; AGENTS stack bullet; ROADMAP Phase 6 item
- grok approval-seam spike: seam confirmed on grok 1.0.41 — Claude-compatible `PreToolUse` hooks with `allow|deny|ask|defer` decisions in `~/.grok/hooks/*.json` (always-trusted global scope); adapter est. ~3–4h

### Security

- Response files now use `mktemp` + `0600` in the user's private `TMPDIR` (daemon recreates at `0600`) — no predictable `/tmp` name for a local process to plant an "allow"

### Changed

- README: uninstall section covers the codex entry, flow diagram covers `PermissionRequest`
- ROADMAP: grok listed as a potential later addition, not a shipped provider; Phase 6 re-triaged (hardening promoted to Recommended Next 3)

## [1.4.0] - 2026-09-26

### Added

- `hookline doctor` — diagnoses the whole chain and restarts a dead/hung daemon
- Daemon health watchdog (launchd `StartInterval` job) plus daemon unit tests and doctor report tests

### Changed

- Heartbeat/SSE staleness handling; roadmap reworked into phases; phone-timeout default shown by `hookline status` fixed

## [1.3.0] - 2026-09-26

### Added

- Multi-provider revival phases 0–4: `HOOKLINE_PROVIDERS` registry gate, core/adapter split, opencode plugin adapter, local custom provider registration
- Release automation (VERSION-triggered release workflow, release-smoke CI) and the shipped roadmap ledger
- First tagged release (earlier milestones: v1.1 stable, v1.2 core — shipped untagged in 2026-06)

[Unreleased]: https://github.com/tsyche/hookline/compare/v1.8.0...HEAD
[1.8.0]: https://github.com/tsyche/hookline/compare/v1.7.1...v1.8.0
[1.7.1]: https://github.com/tsyche/hookline/compare/v1.7.0...v1.7.1
[1.7.0]: https://github.com/tsyche/hookline/compare/v1.6.0...v1.7.0
[1.6.0]: https://github.com/tsyche/hookline/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/tsyche/hookline/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/tsyche/hookline/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/tsyche/hookline/releases/tag/v1.3.0
