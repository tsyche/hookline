#!/usr/bin/env bash
# Sandboxed checks for grok_screen() — the watcher-side screen read that feeds
# the allow-once row parse (Phase 7 bare-terminal capture beyond iTerm2).
# Fake osascript / wezterm / tmux binaries on PATH print a canned permission
# card (or fail), so every backend runs offline with no Apple Accessibility and
# no real terminal. The safety contract: an unreadable screen yields "" → no
# row digit → the injector logs and sends nothing.
#
# Usage: bash scripts/screen-test.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

# shellcheck source=/dev/null
source "$REPO/hooks/adapters/grok.sh"

FAKE_BIN=$(mktemp -d /tmp/hookline-screen.XXXXXX)
trap 'rm -rf "$FAKE_BIN"' EXIT
export SCREEN_TEST_LOG="$FAKE_BIN/calls.log"
export SCREEN_TEST_CARD="$FAKE_BIN/card.txt"

# Canned grok permission card (bash class): allow-once row is 3.
printf '%s\n' \
  '  1 (●) Yes, and don'"'"'t ask again for anything (always-approve mode)' \
  '  2 (○) Always allow: touch /tmp/x' \
  '  3 (○) Yes, proceed' \
  '  4 (○) No, reject (type to add feedback)' \
  > "$SCREEN_TEST_CARD"

# Fake osascript: logs argv; a no-arg call (the iTerm2 heredoc) also logs its
# stdin script, then prints the card.
cat > "$FAKE_BIN/osascript" <<'FAKE'
#!/bin/bash
printf 'osascript %s\n' "$*" >> "${SCREEN_TEST_LOG:?}"
if [ "$#" -eq 0 ]; then cat >> "${SCREEN_TEST_LOG:?}"; fi
cat "${SCREEN_TEST_CARD:?}"
FAKE

# Fake wezterm: logs argv; `cli list --format json` reports pane 7 unfocused
# and pane 9 focused, `cli get-text` serves the card only for 9 (pane id from
# WEZTERM_PANE covers the 42 case).
cat > "$FAKE_BIN/wezterm" <<'FAKE'
#!/bin/bash
printf 'wezterm %s\n' "$*" >> "${SCREEN_TEST_LOG:?}"
case "$*" in
  "cli list --format json")
    printf '%s\n' '[{"pane_id":7,"is_focused":false},{"pane_id":9,"is_focused":true}]'
    ;;
  "cli get-text --pane-id 9"|"cli get-text --pane-id 42")
    cat "${SCREEN_TEST_CARD:?}"
    ;;
  *) exit 1 ;;
esac
FAKE

# Fake tmux: logs argv, prints the card.
cat > "$FAKE_BIN/tmux" <<'FAKE'
#!/bin/bash
printf 'tmux %s\n' "$*" >> "${SCREEN_TEST_LOG:?}"
cat "${SCREEN_TEST_CARD:?}"
FAKE

chmod +x "$FAKE_BIN/osascript" "$FAKE_BIN/wezterm" "$FAKE_BIN/tmux"

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; while IFS= read -r l; do echo "  | $l"; done <<< "$out"; FAIL=$((FAIL + 1)); }

contains() { case "$out" in *"$2"*) pass "$1" ;; *) fail "$1" ;; esac; }
absent() { case "$out" in *"$2"*) fail "$1" ;; *) pass "$1" ;; esac; }
lcontains() { case "$log" in *"$2"*) pass "$1" ;; *) fail_log "$1" ;; esac; }
labsent() { case "$log" in *"$2"*) fail_log "$1" ;; *) pass "$1" ;; esac; }
expect() { # expect <name> <actual> <want>
  if [ "$2" = "$3" ]; then pass "$1"; else
    echo "FAIL $1 (got '$2', want '$3')"; FAIL=$((FAIL + 1)); fi
}
fail_log() { echo "FAIL $1"; while IFS= read -r l; do echo "  | $l"; done <<< "$log"; FAIL=$((FAIL + 1)); }

# run_screen <env KEY=VAL ...> — screen read → $out, row parse → $dig,
# fake-binary calls → $log. Terminal env is cleared first so a real terminal
# running the suite can't leak its own TERM_PROGRAM/TMUX_PANE into "unset"
# cases.
run_screen() {
  : > "$SCREEN_TEST_LOG"
  out=$(env -u TERM_PROGRAM -u TMUX_PANE -u WEZTERM_PANE \
    PATH="$FAKE_BIN:$PATH" "$@" bash -c \
    "source '$REPO/hooks/adapters/grok.sh'; grok_screen" 2>&1)
  dig=$(printf '%s\n' "$out" | grok_allow_digit)
  log=$(cat "$SCREEN_TEST_LOG" 2>/dev/null)
}

# ── 1. tmux: capture-pane of the hook's own pane ──
run_screen TMUX_PANE=1
contains "tmux-capture" '  3 (○) Yes, proceed'
lcontains "tmux-targets-pane" 'tmux capture-pane -p -t 1'
expect "tmux-digit" "$dig" "3"

# ── 2. iTerm2: heredoc session-contents script ──
run_screen TERM_PROGRAM=iTerm.app
contains "iterm-card" '  3 (○) Yes, proceed'
lcontains "iterm-script" 'tell current session of current window to get contents'
expect "iterm-digit" "$dig" "3"

# ── 3. Terminal.app: selected-tab contents (new backend) ──
run_screen TERM_PROGRAM=Apple_Terminal
contains "terminal-card" '  3 (○) Yes, proceed'
lcontains "terminal-script" 'get contents of selected tab of front window'
expect "terminal-digit" "$dig" "3"

# ── 4. WezTerm with WEZTERM_PANE: get-text of that pane ──
run_screen TERM_PROGRAM=WezTerm WEZTERM_PANE=42
contains "wezterm-pane-card" '  3 (○) Yes, proceed'
lcontains "wezterm-pane-get-text" 'wezterm cli get-text --pane-id 42'
labsent "wezterm-pane-no-list" 'cli list'
expect "wezterm-pane-digit" "$dig" "3"

# ── 5. WezTerm without WEZTERM_PANE: focused pane from cli list ──
run_screen TERM_PROGRAM=WezTerm
contains "wezterm-focused-card" '  3 (○) Yes, proceed'
lcontains "wezterm-list" 'wezterm cli list --format json'
lcontains "wezterm-focused-pane" 'wezterm cli get-text --pane-id 9'
labsent "wezterm-ignores-unfocused" 'pane-id 7'
expect "wezterm-focused-digit" "$dig" "3"

# ── 6. unknown terminal: unreadable → "" → no digit, nothing called ──
run_screen TERM_PROGRAM=Hyper
expect "unknown-empty" "$out" ""
expect "unknown-no-call" "$log" ""
expect "unknown-no-digit" "$dig" ""

# ── 7. wezterm binary missing: graceful "" (PATH without the fake + homebrew) ──
chmod -x "$FAKE_BIN/wezterm"
run_screen TERM_PROGRAM=WezTerm WEZTERM_PANE=42
chmod +x "$FAKE_BIN/wezterm"
expect "wezterm-missing-empty" "$out" ""
expect "wezterm-missing-no-digit" "$dig" ""

# ── 8. unreadable screen into the injector's parse: no row → no inject ──
printf '%s\n' '  prompt waiting' > "$SCREEN_TEST_CARD"
run_screen TERM_PROGRAM=Apple_Terminal
expect "no-row-no-digit" "$dig" ""

echo
echo "screen-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
