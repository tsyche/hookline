# Contributing to hookline

Thanks for contributing. This guide covers local testing, the two extension
surfaces (provider adapters, notification backends), and the PR process.

## Ground rules

- **One gate, one source of truth.** CI (`.github/workflows/ci.yml`) runs exactly
  `just check-gates`. Never add a step to the workflow that isn't in the recipe —
  extend the recipe instead so local and CI can't drift.
- **`AGENTS.md` and `CLAUDE.md` are the same file.** Edit either, then run
  `just sync-docs`. `just check-docs` fails the build if they diverge.
- **Docs must match reality.** `just check-docs` validates that every `just`
  recipe mentioned in any Markdown file exists, every repo path referenced in the
  agent docs exists, and relative links resolve.
- **Absolute `/usr/bin/python3`** in hooks, the CLI, and launchd jobs — a bare
  `python3` resolves to an asdf shim that can break the daemon handoff.
- **No private provider ids in app-facing text** (README, roadmap, status copy) —
  use "local" / "custom". Concrete ids live only in untracked config and the code
  that consumes it.

See the "Conventions that bit us" list in [AGENTS.md](AGENTS.md) for the rest of
the do-not-regress list.

## Local development

```bash
just hooks         # opt in: repo-local git hooks (once per clone)
just check-gates   # everything CI runs — run this before every PR
just lint          # shellcheck + Python syntax check
just golden        # hook stdout contract tests (sandboxed, no network)
just test-daemon   # daemon unit tests
just test-plugin   # opencode plugin tests (node --test)
just patterns-test # pattern-CLI tests
just test          # live end-to-end test notification (needs a real topic)
just logs          # tail hook + daemon logs while testing
```

`just hooks` points `core.hooksPath` at the vendored `.githooks/`: pre-commit
keeps `CLAUDE.md` synced from `AGENTS.md` and runs `just check-docs`; pre-push
runs `just check-gates` so nothing broken leaves your machine. Both skip
gracefully when `just` or the recipe is absent, and both accept git's normal
`--no-verify` bypass. CI runs the same checks either way.

`just check-gates` composes: `lint golden test-daemon test-plugin doctor-test
status-test patterns-test install-test release-smoke-test check-docs`. The
sandboxed suites run against a fake `HOME` and never touch the network,
launchd, or your real config.

### Test layers

| Suite | Covers |
|---|---|
| `scripts/hook-golden.sh` | Byte-exact hook stdout contract, end to end from `hooks/hookline.sh` |
| `tests/test_daemon.py` | Registry, notification routing, heartbeat, typed replies, watchdog |
| `tests/test_plugin.mjs` | opencode plugin spawn/reply/dispose paths (fake SDK client) |
| `scripts/doctor-test.sh`, `status-test.sh`, `patterns-test.sh` | CLI report output over prepared fake-HOME layouts |
| `scripts/install-test.sh` | Install/uninstall round trip — inverse operations must leave settings byte-identical |
| `scripts/release-smoke-test.sh` | Release checks via a fake `gh` |
| `scripts/check-docs.sh` | Doc-claim validation (sync, recipes, paths, links) |

### Adding a golden test case

Golden tests pipe a fixture payload into `hooks/hookline.sh <provider>` inside a
sandboxed `HOME` and assert exact stdout (or log side effects). To add one:
append a `run_case` / `run_case_log` / `run_case_notify_payload` /
`run_case_late_answer` call in `scripts/hook-golden.sh` under the matching
section, using the `setup_home` modifiers (`allowlist`, `disabled`,
`providers:<list>`, `noconfig`, `extended`) for the state you need, then run
`just golden`.

## Adding a provider adapter

An adapter is one shell file that translates a tool's payload and decision
format into hookline's core flow. The interface is documented normatively at the
top of `hooks/core.sh` — that comment block is the source of truth.

1. **Create `hooks/adapters/<provider>.sh`** implementing:
   - `ADAPTER_MATCHER` — tool matcher the installer writes into the registration
   - `ADAPTER_RESPONSE_ONLY` — `1` when the daemon must not inject tmux keys
     (provider answers via its own reply API, or needs a different key profile)
   - `HOOKLINE_WAITING_AGENT` — display name in timeout notifications
   - `adapter_normalize` — stdin JSON → `TOOL_NAME`, `TOOL_INPUT`, `CWD`,
     `TRANSCRIPT_PATH`, `SESSION_ID`
   - `adapter_command` — echo the Bash command (empty = not a Bash tool)
   - `adapter_allowlist` — return 0 if auto-approved (emit `defer` yourself)
   - `adapter_emit_decision` / `adapter_emit_initial_decision` — provider
     decision JSON on stdout (or silence, if stdout means decline)
   - `adapter_build_message` — set `NOTIFY_MSG` (question payloads call the
     shared `build_question_message` in `core.sh`)
   - `adapter_progress_lines` — echo a monotonic counter; growth cancels the
     phone flow (the user answered at the terminal)
   - `adapter_inject <allow|deny|answer>` — deliver the phone answer

2. **Register the entry point** so the provider invokes
   `hookline.sh <provider>` with the raw payload on stdin. Registration is
   provider-shaped: Claude-style settings JSON (`register_provider` in
   `install.sh`), a `~/.codex/hooks.json` merge, or a plugin file copy. Add the
   matching inverse to `uninstall.sh` — `just install-test` asserts the two
   invert byte-identically.

3. **Alias if needed.** Provider-id → adapter-file mapping is one case
   statement in `hooks/hookline.sh`; that's the only aliasing point — a
   claude-riding custom provider already takes that arm.

4. **Gate with `HOOKLINE_PROVIDERS`.** No code change needed — the gate in
   `hooks/hookline.sh` accepts any token; ids are free-form. Unset means all
   providers enabled.

5. **Add golden cases** in `scripts/hook-golden.sh`, plus `status`/`doctor`
   report lines in the `hookline` CLI if the provider has its own entry file.

6. **Run `just lint && just golden && just check-gates`.**

Start from an existing adapter: `hooks/adapters/claude.sh` (rich parsing) or
`hooks/adapters/codex.sh` (response-only, hook-side injection).

## Adding a notification backend

ntfy is currently hard-wired at three points; a new backend replaces the
ntfy-specific legs while keeping the transport-neutral JSON contract between
hook and daemon (unix socket messages `type:"notify"` / `type:"status"`):

- **Publish (daemon):** `send_ntfy` in `daemon/hookline-daemon` — payload
  shape, buttons, auth headers.
- **Ingress (daemon):** `sse_listener` — button taps and typed replies on the
  response topic.
- **Legacy publish (no daemon):** `send_notification` and
  `send_timeout_notification` in `hooks/core.sh` — the inline poll loop.
- **Config:** `HOOKLINE_NTFY_*` keys written by `install.sh`, documented in
  README's configuration table, surfaced by `hookline status`/`doctor`
  connectivity checks.
- **Tests:** `TestSendNtfyActions` in `tests/test_daemon.py` asserts the
  payload contract; `scripts/test.sh` is the live manual check.

Keep the socket message schema unchanged so hooks and daemon stay
backend-agnostic, and gate new config behind sensible defaults (public ntfy.sh
stays the out-of-box path).

## Pull requests

- Branch from `main`; history is direct pushes with Conventional Commit
  messages (`feat:`, `fix:`, `docs:`, `chore:`).
- PRs run `just check-gates` via CI — green before review.
- Keep docs in the same PR as the change: update `CHANGELOG.md`
  `[Unreleased]`, and `ROADMAP.md` when a planned item ships.
- Releases are automated: bumping `VERSION` on `main` tags and publishes.
  Run `just changelog-promote` in the same commit as the bump so
  `[Unreleased]` lands in the new entry. Maintainers handle version bumps.
- Dependabot opens grouped monthly PRs for `github-actions` — just make sure
  CI stays green.
