#!/usr/bin/env bash
# Sandboxed checks for `hookline status` — fake HOME, no network, no launchd.
#
# Runs the real CLI against three prepared HOME layouts and asserts the
# status report's daemon section: heartbeat/SSE ages from a live daemon,
# the old-daemon-build fallback when the keys are absent, and the
# not-running case. HOOKLINE_LOCAL_SERVER points connectivity at a local
# http server so nothing leaves the machine.
#
# Usage: bash scripts/status-test.sh
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
  h=$(mktemp -d /tmp/hookline-status.XXXXXX)
  CLEANUP_DIRS+=("$h")
  mkdir -p "$h/.local/share/hookline/hooks" "$h/Library/LaunchAgents" \
           "$h/.config/hookline" "$h/.claude"
  printf '%s\n' \
    'HOOKLINE_TOPIC="status-test-topic"' \
    "HOOKLINE_NTFY_SERVER=\"$1\"" \
    'HOOKLINE_GRACE_PERIOD=20' \
    'HOOKLINE_PHONE_TIMEOUT=900' \
    > "$h/.config/hookline/config"
  printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"/x/hookline.sh claude || true"}]}]}}' \
    > "$h/.claude/settings.json"
  printf '%s' 'fake hook' > "$h/.local/share/hookline/hooks/hookline.sh"
  touch "$h/Library/LaunchAgents/com.hookline.daemon.plist"
  echo "$h"
}

# A daemon stand-in answering status queries. With "ages" it reports fresh
# heartbeat/SSE ages; without it mimics a pre-heartbeat daemon build.
FAKE_DAEMON='
import json, os, socket, sys
path = sys.argv[1]
ages = len(sys.argv) > 2 and sys.argv[2] == "ages"
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
        reply = {"pid": os.getpid(), "sessions": 0, "pending": 0}
        if ages:
            reply["heartbeat_age"] = 0
            reply["sse_age"] = 0
        c.sendall(json.dumps(reply).encode())
    else:
        c.sendall(b"ok")
    c.close()
'

start_fake_daemon() { # start_fake_daemon <home> [ages]
  local sock="$1/.local/share/hookline/daemon.sock"
  rm -f "$sock"
  "$PY" -c "$FAKE_DAEMON" "$sock" "${2:-}" &
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
  out=$(HOME="$home" bash "$CLI" status 2>&1)
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

# ── 1. live daemon with heartbeat build → ages shown, rc=0 ──
h=$(new_home "http://127.0.0.1:9")
port=$(start_http_server "$h") || exit 1
sed -i.bak "s|http://127.0.0.1:9|http://127.0.0.1:${port}|" "$h/.config/hookline/config" && rm -f "$h/.config/hookline/config.bak"
start_fake_daemon "$h" ages || exit 1
run_case "live-daemon-ages" "$h" 0 \
  "running ✓" \
  "heartbeat:  0s" \
  "sse:        0s" \
  "reachable ✓"

# ── 2. old daemon build (no heartbeat keys) → unknown fallback, rc=0 ──
h=$(new_home "http://127.0.0.1:${port}")
start_fake_daemon "$h" || exit 1
run_case "old-daemon-build" "$h" 0 \
  "running ✓" \
  "unknown (old daemon build"

# ── 3. plist present but no daemon → NOT running, rc=0 ──
h=$(new_home "http://127.0.0.1:${port}")
run_case "daemon-down" "$h" 0 \
  "NOT running (installed, not started"

echo
echo "status-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
