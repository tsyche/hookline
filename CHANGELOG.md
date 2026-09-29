# Changelog

Notable changes per release. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

**Release hygiene:** run `just changelog-promote` when bumping `VERSION` so `[Unreleased]` lands in the new entry.

## [Unreleased]

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

[Unreleased]: https://github.com/tsyche/hookline/compare/v1.7.1...HEAD
[1.7.1]: https://github.com/tsyche/hookline/compare/v1.7.0...v1.7.1
[1.7.0]: https://github.com/tsyche/hookline/compare/v1.6.0...v1.7.0
[1.6.0]: https://github.com/tsyche/hookline/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/tsyche/hookline/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/tsyche/hookline/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/tsyche/hookline/releases/tag/v1.3.0
