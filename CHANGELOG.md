# Changelog

Notable changes per release. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

**Release hygiene:** run `just changelog-promote` when bumping `VERSION` so `[Unreleased]` lands in the new entry.

## [Unreleased]

### Added

- Codex adapter: `PermissionRequest` Flow A hook — declines so codex's own approval menu shows, phone answer injects Enter/Esc into the owning tmux pane (frontmost window outside tmux); registration merges `~/.codex/hooks.json` with one-time `/hooks` trust review
- Codex MCP matcher coverage — `mcp__*` tools ride the same decline → menu → phone-answer flow
- `just changelog-promote` — promotes `[Unreleased]` to the current `VERSION` entry (idempotent; run before bumping `VERSION`)
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

[Unreleased]: https://github.com/tsyche/hookline/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/tsyche/hookline/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/tsyche/hookline/releases/tag/v1.3.0
