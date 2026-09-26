#!/usr/bin/env bash
# Sandboxed regression tests for scripts/release-smoke.sh — fake gh, no network.
#
# Builds a throwaway git repo (with two VERSION-bump commits) plus an
# executable `gh` stub ahead of PATH that echoes FAKE_GH_TAG /
# FAKE_GH_TARGET (or fails with FAKE_GH_RC), so all five outcomes — match,
# stale tag, unreadable release, wrong target commit, off-main target —
# run offline and cannot touch the real GitHub API or the real repo.
#
# Usage: bash scripts/release-smoke-test.sh
set -u

PASS=0
FAIL=0

CLEANUP_DIRS=()
cleanup() {
  for d in "${CLEANUP_DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done
}
trap cleanup EXIT

GIT="git -c user.name=smoke -c user.email=smoke@test.invalid"

# ── sandbox repo: v1.0.0 bump, then v1.2.3 bump (= HEAD), plus an orphan ──
repo="$(mktemp -d /tmp/hookline-release-smoke.XXXXXX)"
CLEANUP_DIRS+=("$repo")
mkdir -p "$repo/scripts"
cp "$(cd "$(dirname "$0")" && pwd)/release-smoke.sh" "$repo/scripts/release-smoke.sh"

git -C "$repo" init -q -b main
echo "1.0.0" > "$repo/VERSION"
$GIT -C "$repo" add VERSION && $GIT -C "$repo" commit -qm "v1.0.0"
old_target="$(git -C "$repo" rev-parse HEAD)"
echo "1.2.3" > "$repo/VERSION"
$GIT -C "$repo" commit -qam "v1.2.3"
head_target="$(git -C "$repo" rev-parse HEAD)"
# orphan commit: exists as an object but never reaches main
$GIT -C "$repo" checkout -q --orphan side
$GIT -C "$repo" commit -qm "off-main" --allow-empty
off_target="$(git -C "$repo" rev-parse HEAD)"
$GIT -C "$repo" checkout -q main

# Fake gh: dispatches on the requested JSON field, honors FAKE_GH_RC.
bindir="$(mktemp -d /tmp/hookline-release-smoke.XXXXXX)"
CLEANUP_DIRS+=("$bindir")
cat > "$bindir/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${FAKE_GH_RC:-0}" -ne 0 ]; then
  echo "no releases found" >&2
  exit "${FAKE_GH_RC}"
fi
case "$*" in
  *targetCommitish*) echo "${FAKE_GH_TARGET}" ;;
  *)                  echo "${FAKE_GH_TAG}" ;;
esac
EOF
chmod +x "$bindir/gh"

# run_case <name> <expected-rc> <tag> <target> <gh-rc> <pattern>...
run_case() {
  local name="$1" want_rc="$2" tag="$3" target="$4" gh_rc="$5"
  shift 5
  local out rc ok=1 pat
  out="$(cd "$repo" && FAKE_GH_TAG="$tag" FAKE_GH_TARGET="$target" FAKE_GH_RC="$gh_rc" \
        PATH="$bindir:$PATH" bash scripts/release-smoke.sh 2>&1)"
  rc=$?

  [ "$rc" -eq "$want_rc" ] || ok=0
  for pat in "$@"; do
    case "$out" in
      *"$pat"*) ;;
      *) ok=0; echo "  missing pattern: $pat" ;;
    esac
  done

  if [ "$ok" -eq 1 ]; then
    echo "PASS $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL $name (rc=$rc, want rc=$want_rc)"
    while IFS= read -r line; do echo "  | $line"; done <<< "$out"
    FAIL=$((FAIL + 1))
  fi
}

# ── 1. tag == VERSION, target = HEAD on main → ok, rc=0 ──
run_case "match" 0 "v1.2.3" "$head_target" 0 \
  "ok" \
  "matches VERSION and targets main@"

# ── 2. stale release tag → FAIL, rc=1 ──
run_case "stale-tag" 1 "v0.0.1" "$head_target" 0 \
  "FAIL" \
  "!= VERSION 'v1.2.3'"

# ── 3. no releases at all (gh errors) → FAIL, rc=1 ──
run_case "no-release" 1 "" "" 1 \
  "FAIL" \
  "cannot read latest release"

# ── 4. tag right but targets an off-main commit → FAIL, rc=1 ──
run_case "off-main-target" 1 "v1.2.3" "$off_target" 0 \
  "FAIL" \
  "not an ancestor of HEAD"

# ── 5. tag right, target on main but at the old VERSION bump → FAIL ──
run_case "wrong-target-version" 1 "v1.2.3" "$old_target" 0 \
  "FAIL" \
  "has VERSION=1.0.0"

echo
echo "release-smoke-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
