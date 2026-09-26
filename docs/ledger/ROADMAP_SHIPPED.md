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
