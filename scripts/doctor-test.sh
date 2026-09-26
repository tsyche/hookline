#!/bin/bash
# Sandboxed checks for `hookline doctor` — fake HOME, no network, no launchd.
#
# Runs the real CLI against four prepared HOME layouts and asserts the
# doctor's report lines and exit code. HOOKLINE_DOCTOR_NO_FIX=1 keeps every
# run report-only, so the recipe can never touch the machine's real launchd
# jobs even when the repo lives on a machine with hookline installed.
#
# Usage: bash scripts/doctor-test.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$REPO/hookline"
PY="/usr/bin/python3"
[ -x "$PY" ] || PY="$(command -v python3)"
PASS=0
FAIL=0

CLEANUP_PIDS=()
CLEANUP_DIRS=()
cleanup() {
  for pid in "${CLEANUP_PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
  for d in "${CLEANUP_DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done
}
trap cleanup EXIT

new_home() {
  local h
  h=$(mktemp -d /tmp/hookline-doctor.XXXXXX)
  CLEANUP_DIRS+=("$h")
  mkdir -p "$h/.local/share/hookline/hooks" "$h/Library/LaunchAgents" \
           "$h/.config/hookline" "$h/.claude"
  printf '%s\n' \
    'HOOKLINE_TOPIC="doctor-test-topic"' \
    "HOOKLINE_NTFY_SERVER=\"$1\"" \
    'HOOKLINE_GRACE_PERIOD=20' \
    'HOOKLINE_PHONE_TIMEOUT=900' \
    > "$h/.config/hookline/config"
  printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"/x/hookline.sh claude || true"}]}]}}' \
    > "$h/.claude/settings.json"
  printf '%s' 'fake hook' > "$h/.local/share/hookline/hooks/hookline.sh"
  touch "$h/Library/LaunchAgents/com.hookline.daemon.plist"
  touch "$h/Library/LaunchAgents/com.hookline.watchdog.plist"
  echo "$h"
}

# A daemon stand-in that answers status queries on the unix socket.
FAKE_DAEMON='
import json, os, socket, sys
path = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.listen(5)
while True:
    c, _ = s.accept()
    data = b""
    while True:
        chunk = c.recv(4096)
        if not chunk:
            break
        data += chunk
    try:
        msg = json.loads(data.decode())
    except Exception:
        msg = {}
    if msg.get("type") == "status":
        c.sendall(json.dumps({"pid": os.getpid(), "sessions": 0, "pending": 0,
                              "heartbeat_age": 0, "sse_age": 0}).encode())
    else:
        c.sendall(b"ok")
    c.close()
'

start_fake_daemon() { # start_fake_daemon <home>
  local sock="$1/.local/share/hookline/daemon.sock"
  rm -f "$sock"
  "$PY" -c "$FAKE_DAEMON" "$sock" &
  CLEANUP_PIDS+=($!)
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -S "$sock" ] && return 0
    sleep 0.2
  done
  echo "fake daemon failed to bind $sock"
  return 1
}

start_http_server() { # start_http_server <home> -> echoes port
  local port
  port=$("$PY" -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
  "$PY" -m http.server "$port" --bind 127.0.0.1 --directory "$1" >/dev/null 2>&1 &
  CLEANUP_PIDS+=($!)
  for _ in 1 2 3 4 5; do
    if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$port/"; then
      echo "$port"
      return 0
    fi
    sleep 0.2
  done
  echo "http server failed on $port"
  return 1
}

# run_case <name> <home> <expected-rc> <pattern>...  (all patterns must appear)
run_case() {
  local name="$1" home="$2" want_rc="$3"
  shift 3
  local out rc ok=1 pat
  out=$(HOME="$home" HOOKLINE_DOCTOR_NO_FIX=1 bash "$CLI" doctor 2>&1)
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

[ -f "$CLI" ] || { echo "CLI not found: $CLI"; exit 1; }

# ── 1. empty HOME: nothing installed → reports every gap, rc=1 ──
h=$(mktemp -d /tmp/hookline-doctor.XXXXXX)
CLEANUP_DIRS+=("$h")
run_case "empty-home" "$h" 1 \
  "config not found" \
  "hook file missing" \
  "daemon not installed" \
  "watchdog not installed" \
  "skipped (no config)"

# ── 2. healthy install: fake daemon + local ntfy → all green, rc=0 ──
h=$(new_home "http://127.0.0.1:9")
port=$(start_http_server "$h") || exit 1
sed -i.bak "s|http://127.0.0.1:9|http://127.0.0.1:${port}|" "$h/.config/hookline/config" && rm -f "$h/.config/hookline/config.bak"
mkdir -p "$h/.config/opencode/plugins"
printf '%s' '// plugin' > "$h/.config/opencode/plugins/hookline.js"
start_fake_daemon "$h" || exit 1
run_case "healthy-install" "$h" 0 \
  "daemon responsive (pid=" \
  "heartbeat 0s" \
  "sse 0s" \
  "reachable: http://127.0.0.1:${port}" \
  "0 failed"

# ── 3. daemon down (no listener) → detected, fix disabled, rc=1 ──
h=$(new_home "http://127.0.0.1:9")
run_case "daemon-down" "$h" 1 \
  "daemon not running" \
  "fix disabled (HOOKLINE_DOCTOR_NO_FIX)" \
  "could not auto-fix"

# ── 4. stale socket file with no listener → detected as stale socket, rc=1 ──
h=$(new_home "http://127.0.0.1:9")
"$PY" -c "
import socket, os
p = os.path.join('$h', '.local/share/hookline/daemon.sock')
s = socket.socket(socket.AF_UNIX)
s.bind(p)
s.close()
"
run_case "stale-socket" "$h" 1 \
  "stale socket file" \
  "could not auto-fix"

echo
echo "doctor-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
