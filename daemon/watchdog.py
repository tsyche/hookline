#!/usr/bin/env python3
"""hookline watchdog — restarts the daemon when its heartbeat goes stale.

KeepAlive only restarts the daemon when it *exits*; a hung-but-alive process
(SSE frozen after a 502 storm or system sleep) keeps running while phone
responses stop arriving. This job runs on a launchd StartInterval and
restarts the daemon when either heartbeat is stale:

  heartbeat     — touched every serve-loop iteration (~1s): daemon main loop dead
  sse-heartbeat — touched on SSE connect/receive (bounded by the read timeout):
                  instant-response path dead while the main loop still answers

It never fights an intentional stop: when the daemon job is unloaded
(`hookline daemon stop`), the launchd check reports "not loaded" and the
watchdog exits quietly.

Run directly (as launchd does): /usr/bin/python3 watchdog.py
"""

import os
import subprocess
import sys
import time

HEARTBEAT_PATH     = os.path.expanduser("~/.local/share/hookline/heartbeat")
SSE_HEARTBEAT_PATH = os.path.expanduser("~/.local/share/hookline/sse-heartbeat")
DAEMON_PLIST       = os.path.expanduser("~/Library/LaunchAgents/com.hookline.daemon.plist")
DAEMON_LABEL       = "com.hookline.daemon"

HEARTBEAT_MAX_AGE = 120  # serve loop ticks ~1s; 2min covers sleep-wake jitter
SSE_MAX_AGE       = 600  # 2x the daemon's SSE read timeout (300s)


def file_age(path, now=None):
    """Seconds since path was last modified, or None when missing."""
    try:
        now = time.time() if now is None else now
        return now - os.path.getmtime(path)
    except OSError:
        return None


def is_stale(path, max_age, now=None):
    """Missing counts as stale — a loaded daemon touches both files at start."""
    age = file_age(path, now)
    return age is None or age > max_age


def decide(daemon_installed, daemon_loaded, heartbeat_stale, sse_stale):
    """Pure decision: what the watchdog should do for this pass."""
    if not daemon_installed:
        return "skip-not-installed"
    if not daemon_loaded:
        return "skip-not-loaded"
    if heartbeat_stale or sse_stale:
        return "restart"
    return "ok"


def daemon_loaded():
    """True when the daemon job is registered with launchd (even if hung)."""
    return subprocess.run(
        ["launchctl", "list", DAEMON_LABEL],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0


def restart_daemon():
    uid = os.getuid()
    result = subprocess.run(
        ["launchctl", "kickstart", "-k", f"gui/{uid}/{DAEMON_LABEL}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    if result.returncode != 0:
        # Legacy-loaded jobs can reject kickstart; fall back to unload/load.
        subprocess.run(
            ["launchctl", "unload", DAEMON_PLIST],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        subprocess.run(
            ["launchctl", "load", DAEMON_PLIST],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )


def main():
    action = decide(
        daemon_installed=os.path.exists(DAEMON_PLIST),
        daemon_loaded=daemon_loaded(),
        heartbeat_stale=is_stale(HEARTBEAT_PATH, HEARTBEAT_MAX_AGE),
        sse_stale=is_stale(SSE_HEARTBEAT_PATH, SSE_MAX_AGE),
    )
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    if action == "restart":
        hb = file_age(HEARTBEAT_PATH)
        sse = file_age(SSE_HEARTBEAT_PATH)
        print(f"[{stamp}] restarting daemon (heartbeat={hb}s sse={sse}s)")
        restart_daemon()
    elif action == "ok":
        # Verbose only when a heartbeat is misbehaving near the threshold.
        hb = file_age(HEARTBEAT_PATH)
        if hb is not None and hb > HEARTBEAT_MAX_AGE // 2:
            print(f"[{stamp}] heartbeat {int(hb)}s (under {HEARTBEAT_MAX_AGE}s, ok)")
    # skip-*: intentional stop or nothing installed — stay quiet.
    return 0


if __name__ == "__main__":
    sys.exit(main())
