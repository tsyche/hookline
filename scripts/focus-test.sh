#!/usr/bin/env bash
# Sandboxed checks for focus_prompt_window (Phase 7 bare-terminal multi-session
# targeting) — HOOKLINE_FOCUS_DRY_RUN=1 prints the focus command instead of
# running osascript/wezterm, so assertions run offline with no Accessibility
# or terminal-control requirements.
#
# Usage: bash scripts/focus-test.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

# Source just the function: core.sh's top level only defines PYBIN + helpers.
# shellcheck source=/dev/null
source "$REPO/hooks/core.sh"

run_focus() { # run_focus <extra env KEY=VAL ...> — output in $out, rc in $rc
  # Clear terminal env first — the test may run inside a real terminal whose
  # TERM_PROGRAM/TERM_SESSION_ID would otherwise leak into "unset" cases.
  out=$(env -u TERM_PROGRAM -u TERM_SESSION_ID -u WEZTERM_PANE \
    HOOKLINE_FOCUS_DRY_RUN=1 "$@" bash -c \
    "source '$REPO/hooks/core.sh'; focus_prompt_window" 2>&1)
  rc=$?
}

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; while IFS= read -r l; do echo "  | $l"; done <<< "$out"; FAIL=$((FAIL + 1)); }

contains() { # contains <name> <needle>
  case "$out" in *"$2"*) pass "$1" ;; *) fail "$1" ;; esac
}
absent() { # absent <name> <needle>
  case "$out" in *"$2"*) fail "$1" ;; *) pass "$1" ;; esac
}
expect_rc() { # expect_rc <name> <want:0|nonzero>
  if [ "$2" = "0" ] && [ "$rc" -eq 0 ]; then pass "$1"
  elif [ "$2" = "nonzero" ] && [ "$rc" -ne 0 ]; then pass "$1"
  else fail "$1 (rc=$rc, wanted $2)"; fi
}

# ── 1. iTerm2: prefixed TERM_SESSION_ID → selects UUID suffix session ──
run_focus TERM_PROGRAM=iTerm.app TERM_SESSION_ID="w0t1p2:EE10DC2D-81E3-4357-B9B2-38EA13CDE463"
expect_rc "iterm-prefixed-rc" 0
contains "iterm-prefixed-selects-uuid" 'set want to "EE10DC2D-81E3-4357-B9B2-38EA13CDE463"'
absent "iterm-prefixed-strips-prefix" 'w0t1p2:EE10DC2D'

# ── 2. iTerm2: bare UUID session id (older builds) passes through ──
run_focus TERM_PROGRAM=iTerm.app TERM_SESSION_ID="1BDECB41-1FF3-4917-8A1E-055B806AFEF9"
expect_rc "iterm-bare-rc" 0
contains "iterm-bare-selects-id" 'set want to "1BDECB41-1FF3-4917-8A1E-055B806AFEF9"'

# ── 3. iTerm2 without TERM_SESSION_ID → no stable id, fallback signaled ──
run_focus TERM_PROGRAM=iTerm.app
expect_rc "iterm-no-id-rc" nonzero
absent "iterm-no-id-no-osascript" 'osascript'

# ── 4. WezTerm: WEZTERM_PANE → activate-pane --pane-id ──
run_focus TERM_PROGRAM=WezTerm WEZTERM_PANE="42"
expect_rc "wezterm-rc" 0
contains "wezterm-activates-pane" 'wezterm cli activate-pane --pane-id 42'

# ── 5. WezTerm without WEZTERM_PANE → fallback signaled ──
run_focus TERM_PROGRAM=WezTerm
expect_rc "wezterm-no-pane-rc" nonzero
absent "wezterm-no-pane-no-cli" 'activate-pane'

# ── 6. Terminal.app → no stable id, frontmost fallback kept ──
run_focus TERM_PROGRAM=Apple_Terminal TERM_SESSION_ID="whatever"
expect_rc "terminal-app-rc" nonzero
absent "terminal-app-no-osascript" 'osascript'

# ── 7. Unknown terminal → fallback ──
run_focus TERM_PROGRAM=vscode TERM_SESSION_ID="whatever"
expect_rc "unknown-rc" nonzero

# ── 8. No TERM_PROGRAM at all → fallback ──
run_focus
expect_rc "unset-rc" nonzero

echo
echo "focus-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
