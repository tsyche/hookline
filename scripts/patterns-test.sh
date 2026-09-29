#!/usr/bin/env bash
# Sandboxed checks for the pattern-management CLI — fake HOME, no network.
#
# Exercises `hookline patterns`, `remove-pattern`, and `clear-patterns`
# against prepared project/global settings files: listing both scopes,
# bare-pattern normalization, not-found errors, preservation of unrelated
# JSON keys and file mode, allow-key cleanup, and invalid-JSON refusal.
#
# Usage: bash scripts/patterns-test.sh
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

# new_sandbox → echoes "<home> <workdir>" with settings files prepared.
new_sandbox() {
  local h w
  h=$(mktemp -d /tmp/hookline-patterns.XXXXXX)
  CLEANUP_DIRS+=("$h")
  w="$h/work"
  mkdir -p "$w/.claude" "$h/.claude"
  printf '%s' '{"permissions":{"allow":["Bash(git status*)","Bash(just lint)","Read(~/x/**)"]},"model":"opus"}' \
    > "$w/.claude/settings.local.json"
  printf '%s' '{"permissions":{"allow":["Bash(safe*)"]},"hooks":{}}' \
    > "$h/.claude/settings.json"
  chmod 644 "$w/.claude/settings.local.json"
  printf '%s %s\n' "$h" "$w"
}

# run <home> <workdir> <expected-rc> <cmd...> — sets OUT/RC.
run() {
  local home="$1" work="$2" want_rc="$3"
  shift 3
  OUT=$(cd "$work" && HOME="$home" bash "$CLI" "$@" 2>&1)
  RC=$?
  [ "$RC" -eq "$want_rc" ]
}

# assert_out <name> <pattern>... — all patterns must appear in OUT.
assert_out() {
  local name="$1" ok=1 pat
  shift
  for pat in "$@"; do
    case "$OUT" in
      *"$pat"*) ;;
      *) ok=0; echo "  missing pattern: $pat" ;;
    esac
  done
  report "$name" "$ok"
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

[ -f "$CLI" ] || { echo "CLI not found: $CLI"; exit 1; }

# ── 1. list shows both scopes, flags non-Bash entries, rc=0 ──
read -r h w <<< "$(new_sandbox)"
run "$h" "$w" 0 patterns
assert_out "list-both-scopes" \
  "project (" "global (" \
  "Bash(git status*)" "Bash(just lint)" \
  "Read(~/x/**)  (not consulted by the hook)" "Bash(safe*)"

# ── 2. remove bare pattern → normalized to Bash(...), unrelated keys kept ──
read -r h w <<< "$(new_sandbox)"
run "$h" "$w" 0 remove-pattern "git status*"
assert_out "remove-bare" "removed Bash(git status*) from"
left=$(cat "$w/.claude/settings.local.json")
ok=1
grep -qF '"Bash(just lint)"' <<<"$left" || ok=0
grep -qF '"model": "opus"' <<<"$left" || ok=0
grep -qF '"Bash(git status*)"' <<<"$left" && ok=0
report "remove-keeps-siblings" "$ok"
mode=$(stat -c '%a' "$w/.claude/settings.local.json" 2>/dev/null || stat -f '%Lp' "$w/.claude/settings.local.json" 2>/dev/null)
if [ "$mode" = "644" ]; then OUT=$mode; report "remove-preserves-mode" 1
else OUT=$mode; report "remove-preserves-mode" 0; fi

# ── 3. remove missing pattern → rc=1, file untouched ──
read -r h w <<< "$(new_sandbox)"
before=$(cat "$w/.claude/settings.local.json")
run "$h" "$w" 1 remove-pattern "Bash(nope)"
assert_out "remove-not-found" "pattern not found" "hookline patterns"
after=$(cat "$w/.claude/settings.local.json")
if [ "$before" = "$after" ]; then report "not-found-leaves-file" 1
else OUT=$after; report "not-found-leaves-file" 0; fi

# ── 4. remove --global targets the global file only ──
read -r h w <<< "$(new_sandbox)"
run "$h" "$w" 0 remove-pattern --global "safe*"
assert_out "remove-global" "removed Bash(safe*) from $h/.claude/settings.json"
case "$(cat "$h/.claude/settings.json")" in
  *'allow'*|*'Bash(safe*)'*) OUT=$(cat "$h/.claude/settings.json"); report "global-cleared" 0 ;;
  *) report "global-cleared" 1 ;;
esac
case "$(cat "$w/.claude/settings.local.json")" in
  *'Bash(git status*)'*) report "project-untouched" 1 ;;
  *) OUT=$(cat "$w/.claude/settings.local.json"); report "project-untouched" 0 ;;
esac

# ── 5. clear-patterns wipes allow but keeps sibling keys; then no-op rc=0 ──
read -r h w <<< "$(new_sandbox)"
run "$h" "$w" 0 clear-patterns
assert_out "clear-report" "cleared 3 entries"
left=$(cat "$w/.claude/settings.local.json")
case "$left" in
  *'"allow"'*) OUT=$left; report "clear-drops-allow-key" 0 ;;
  *'"model": "opus"'*) report "clear-drops-allow-key" 1 ;;
  *) OUT=$left; report "clear-drops-allow-key" 0 ;;
esac
run "$h" "$w" 0 clear-patterns
assert_out "clear-noop" "nothing to clear"

# ── 6. missing file → remove rc=1, clear rc=0 ──
read -r h w <<< "$(new_sandbox)"
rm "$w/.claude/settings.local.json"
run "$h" "$w" 1 remove-pattern "whatever"
assert_out "remove-missing-file" "no allowlist file"
run "$h" "$w" 0 clear-patterns
assert_out "clear-missing-file" "no allowlist file" "nothing to clear"

# ── 7. invalid JSON → rc=1 with diagnostic, file never rewritten ──
read -r h w <<< "$(new_sandbox)"
printf 'nope' > "$h/.claude/settings.json"
run "$h" "$w" 1 patterns
assert_out "list-bad-json" "is not valid JSON"

echo
echo "patterns-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
