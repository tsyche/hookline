#!/usr/bin/env bash
# Sandboxed checks for `hookline snooze` — fake HOME, no network, no daemon.
#
# Exercises the mute-window CLI: status when off/expired/active, setting a
# window (file epoch + message), extension, clearing (off / 0 / clear),
# invalid input, and the `hookline status` snooze section. The connectivity
# probe inside `status` points at a closed local port so nothing leaves the
# machine.
#
# Usage: bash scripts/snooze-test.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$REPO/hookline"
PASS=0
FAIL=0

CLEANUP_DIRS=()
cleanup() {
  for d in "${CLEANUP_DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done
}
trap cleanup EXIT

# new_home → sandbox HOME with the share dir prepared; echoes the path.
new_home() {
  local h
  h=$(mktemp -d /tmp/hookline-snooze.XXXXXX)
  CLEANUP_DIRS+=("$h")
  mkdir -p "$h/.local/share/hookline"
  echo "$h"
}

# run <home> <expected-rc> <cmd...> — sets OUT/RC.
run() {
  local home="$1" want_rc="$2"
  shift 2
  OUT=$(HOME="$home" HOOKLINE_NTFY_SERVER="http://127.0.0.1:9" \
        bash "$CLI" "$@" 2>&1)
  RC=$?
  [ "$RC" -eq "$want_rc" ]
}

report() {
  if [ "$2" -eq 1 ]; then
    echo "PASS $1"
    PASS=$((PASS + 1))
  else
    echo "FAIL $1"
    while IFS= read -r line; do echo "  | $line"; done <<< "$OUT"
    FAIL=$((FAIL + 1))
  fi
}

# has <substring>... — all must appear in OUT.
has() {
  local pat ok=1
  for pat in "$@"; do
    case "$OUT" in *"$pat"*) ;; *) ok=0; echo "  missing: $pat" ;; esac
  done
  [ "$ok" -eq 1 ]
}

snooze_file() { echo "$1/.local/share/hookline/snooze"; }

# ── status: off by default ──
H=$(new_home)
ok=1
run "$H" 0 snooze && has "snooze: off" || ok=0
report "status-off-by-default" "$ok"

# ── set 60: message + future epoch inside the window ──
ok=1
run "$H" 0 snooze 60 && has "muted for 60m" "(until " || ok=0
now=$(date +%s)
exp=$(cat "$(snooze_file "$H")" 2>/dev/null || echo 0)
[ "$exp" -ge "$(( now + 3540 ))" ] || { ok=0; echo "  epoch too early: $exp"; }
[ "$exp" -le "$(( now + 3660 ))" ] || { ok=0; echo "  epoch too late: $exp"; }
report "set-60-writes-future-epoch" "$ok"

# ── status: active, shows remaining minutes ──
ok=1
run "$H" 0 snooze && has "active" "muted until" "m left" || ok=0
report "status-active-shows-until-and-left" "$ok"

# ── set 30: shrinks the existing window ──
ok=1
run "$H" 0 snooze 30 && has "muted for 30m" || ok=0
exp=$(cat "$(snooze_file "$H")")
[ "$exp" -ge "$(( now + 1740 ))" ] && [ "$exp" -le "$(( now + 1860 ))" ] \
  || { ok=0; echo "  epoch not ~30m: $exp"; }
report "set-30-extends-shorter" "$ok"

# ── off clears the file ──
ok=1
run "$H" 0 snooze off && has "cleared" "enabled" || ok=0
[ ! -f "$(snooze_file "$H")" ] || { ok=0; echo "  file still present"; }
report "off-clears-window" "$ok"

# ── 0 clears too ──
ok=1
run "$H" 0 snooze 45 || ok=0
run "$H" 0 snooze 0 && has "cleared" || ok=0
[ ! -f "$(snooze_file "$H")" ] || { ok=0; echo "  file still present"; }
report "zero-clears-window" "$ok"

# ── clear alias ──
ok=1
run "$H" 0 snooze 15 || ok=0
run "$H" 0 snooze clear && has "cleared" || ok=0
[ ! -f "$(snooze_file "$H")" ] || { ok=0; echo "  file still present"; }
report "clear-alias-clears-window" "$ok"

# ── invalid input: rc 1 + usage, file untouched ──
for bad in abc -5 10x "12 30"; do
  ok=1
  run "$H" 1 snooze "$bad" && has "positive integer" || ok=0
  [ ! -f "$(snooze_file "$H")" ] || { ok=0; echo "  file created"; }
  report "invalid-input-$bad" "$ok"
done

# ── expired window: status says so, rc 0 ──
echo $(( $(date +%s) - 60 )) > "$(snooze_file "$H")"
ok=1
run "$H" 0 snooze && has "snooze: off (window expired)" || ok=0
report "expired-window-status" "$ok"

# ── `hookline status` snooze section: off and active ──
rm -f "$(snooze_file "$H")"
ok=1
run "$H" 0 status && has "── snooze" "  off" || ok=0
report "status-section-off" "$ok"

run "$H" 0 snooze 25 || ok=1
ok=1
run "$H" 0 status && has "── snooze" "  active — muted until" || ok=0
report "status-section-active" "$ok"

echo
echo "snooze-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
