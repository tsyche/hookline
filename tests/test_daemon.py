#!/usr/bin/env python3
"""Unit tests for the hookline daemon (stdlib only — no external deps).

Covers the session registry, phone-response routing (tmux injection vs
response-file), heartbeat staleness, and the watchdog's restart decision.

Run: /usr/bin/python3 -m unittest discover -s tests -p 'test_*.py'
"""

import importlib.machinery
import importlib.util
import json
import os
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from unittest import mock

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The daemon and watchdog bake HOME-derived paths at import time, so the
# sandbox HOME must be in place before loading them. Isolated test process.
# Under /tmp on purpose: AF_UNIX paths cap at 104 chars and mkdtemp's default
# location (/var/folders/...) overflows once the daemon appends daemon.sock.
HOME = tempfile.mkdtemp(prefix="hdt.", dir="/tmp")
os.environ["HOME"] = HOME
os.makedirs(os.path.join(HOME, ".local/share/hookline"), exist_ok=True)


def load(name, relpath):
    # SourceFileLoader: the daemon file has no .py extension, so the default
    # spec factory finds no loader and returns None.
    path = os.path.join(REPO, relpath)
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


daemon_mod  = load("hookline_daemon",  "daemon/hookline-daemon")
watchdog_mod = load("hookline_watchdog", "daemon/watchdog.py")


def tearDownModule():
    import shutil
    shutil.rmtree(HOME, ignore_errors=True)


def exchange(d, payload):
    """Drive handle_connection over a real unix socketpair, reply or None."""
    client, server = socket.socketpair()
    try:
        client.sendall(json.dumps(payload).encode())
        client.shutdown(socket.SHUT_WR)
        d.handle_connection(server)
        try:
            client.settimeout(2)
            return client.recv(4096)
        except socket.timeout:
            return b""
    finally:
        client.close()


class TestRegistry(unittest.TestCase):
    def setUp(self):
        self.d = daemon_mod.Daemon()

    def test_register_stores_routing_info(self):
        reply = exchange(self.d, {
            "type": "register", "session_id": "s1", "tty": "ttys001",
            "term_program": "iTerm.app", "tmux_pane": "%3", "tmux_socket": "/tmp/t.sock",
        })
        self.assertEqual(reply, b"ok")
        self.assertEqual(self.d.sessions["s1"]["tty"], "ttys001")
        self.assertEqual(self.d.sessions["s1"]["tmux_pane"], "%3")
        self.assertEqual(self.d.sessions["s1"]["tmux_socket"], "/tmp/t.sock")

    def test_cancel_removes_pending(self):
        self.d.pending["r1"] = "s1"
        reply = exchange(self.d, {"type": "cancel", "req_id": "r1"})
        self.assertEqual(reply, b"ok")
        self.assertNotIn("r1", self.d.pending)

    def test_status_reports_counts_and_heartbeat_ages(self):
        self.d.sessions["s1"] = {}
        self.d.sessions["s2"] = {}
        self.d.pending["r1"] = "s1"
        reply = json.loads(exchange(self.d, {"type": "status"}).decode())
        self.assertEqual(reply["sessions"], 2)
        self.assertEqual(reply["pending"], 1)
        self.assertEqual(reply["pid"], os.getpid())
        self.assertIn("heartbeat_age", reply)
        self.assertIn("sse_age", reply)

    def test_unknown_type_gets_unknown(self):
        self.assertEqual(exchange(self.d, {"type": "wat"}), b"unknown")


class TestNotify(unittest.TestCase):
    def setUp(self):
        self.d = daemon_mod.Daemon()
        self.sent = []
        self.d.send_ntfy = lambda config, title, message, req_id: \
            self.sent.append((title, message, req_id)) or True

    def test_notify_registers_pending_and_session(self):
        reply = exchange(self.d, {
            "type": "notify", "session_id": "s1", "req_id": "r1",
            "title": "t", "message": "m", "response_file": "/tmp/r", "max_retries": 3,
        })
        self.assertEqual(reply, b"ok")
        self.assertEqual(self.d.pending, {"r1": "s1"})
        self.assertEqual(self.d.sessions["s1"]["response_file"], "/tmp/r")
        self.assertEqual(self.d.sessions["s1"]["max_retries"], 3)
        self.assertEqual(len(self.sent), 1)

    def test_notify_supersedes_previous_request_for_session(self):
        exchange(self.d, {"type": "notify", "session_id": "s1", "req_id": "r1"})
        exchange(self.d, {"type": "notify", "session_id": "s1", "req_id": "r2"})
        self.assertNotIn("r1", self.d.pending)
        self.assertEqual(self.d.pending, {"r2": "s1"})


class TestResponseRouting(unittest.TestCase):
    def setUp(self):
        self.d = daemon_mod.Daemon()

    def register(self, tmux_pane="", response_file=""):
        self.d.sessions["s1"] = {"tmux_pane": tmux_pane, "tmux_socket": "/tmp/t.sock",
                                 "response_file": response_file}
        self.d.pending["r1"] = "s1"

    def test_allow_via_tmux_sends_1_enter(self):
        self.register(tmux_pane="%1")
        with mock.patch.object(daemon_mod, "TMUX_BIN", "/usr/bin/tmux"), \
             mock.patch.object(daemon_mod.subprocess, "run") as run:
            run.return_value.returncode = 0
            self.d.handle_response("r1", "allow")
        run.assert_called_once_with(
            ["/usr/bin/tmux", "-S", "/tmp/t.sock", "send-keys", "-t", "%1", "1", "Enter"],
            capture_output=True,
        )
        self.assertNotIn("r1", self.d.pending)

    def test_deny_via_tmux_sends_escape(self):
        self.register(tmux_pane="%1")
        with mock.patch.object(daemon_mod, "TMUX_BIN", "/usr/bin/tmux"), \
             mock.patch.object(daemon_mod.subprocess, "run") as run:
            run.return_value.returncode = 0
            self.d.handle_response("r1", "deny")
        keys = run.call_args[0][0]
        self.assertIn("Escape", keys)
        self.assertNotIn("Enter", keys)

    def test_allow_without_tmux_writes_response_file(self):
        rf = os.path.join(HOME, "resp-allow")
        self.register(response_file=rf)
        with mock.patch.object(daemon_mod.subprocess, "run") as run:
            self.d.handle_response("r1", "allow")
        run.assert_not_called()
        with open(rf) as f:
            self.assertEqual(f.read(), "allow")
        self.assertNotIn("r1", self.d.pending)

    def test_retry_writes_retry_and_clears_pending(self):
        rf = os.path.join(HOME, "resp-retry")
        self.register(response_file=rf)
        self.d.handle_response("r1", "retry")
        with open(rf) as f:
            self.assertEqual(f.read(), "retry")
        self.assertNotIn("r1", self.d.pending)

    def test_unknown_req_id_is_ignored(self):
        with mock.patch.object(daemon_mod.subprocess, "run") as run:
            self.d.handle_response("nope", "allow")
        run.assert_not_called()
        self.assertEqual(self.d.pending, {})


class TestHeartbeat(unittest.TestCase):
    def test_touch_and_age_roundtrip(self):
        path = os.path.join(HOME, "hb-test")
        self.assertEqual(daemon_mod.age(path), -1)
        daemon_mod.touch(path)
        self.assertGreaterEqual(daemon_mod.age(path), 0)
        self.assertFalse(daemon_mod.age(path) < 0)

    def test_serve_loop_touches_heartbeat_and_answers_status(self):
        d = daemon_mod.Daemon()
        thread = threading.Thread(target=d.serve, daemon=True)
        thread.start()
        try:
            deadline = time.time() + 5
            while time.time() < deadline and not os.path.exists(daemon_mod.SOCKET_PATH):
                time.sleep(0.1)
            self.assertTrue(os.path.exists(daemon_mod.SOCKET_PATH), "socket never bound")

            client = socket.socket(socket.AF_UNIX)
            client.settimeout(3)
            client.connect(daemon_mod.SOCKET_PATH)
            client.sendall(json.dumps({"type": "status"}).encode())
            client.shutdown(socket.SHUT_WR)
            reply = json.loads(client.recv(4096).decode())
            client.close()
            self.assertEqual(reply["pid"], os.getpid())
            self.assertGreaterEqual(reply["heartbeat_age"], 0)

            first = os.path.getmtime(daemon_mod.HEARTBEAT_PATH)
            time.sleep(1.5)
            second = os.path.getmtime(daemon_mod.HEARTBEAT_PATH)
            self.assertGreater(second, first, "serve loop stopped touching heartbeat")
        finally:
            d._stop.set()
            thread.join(timeout=5)

    def test_start_touches_both_heartbeats_before_threads(self):
        d = daemon_mod.Daemon()
        # start() blocks in serve(); exercise just its prologue via serve-fake.
        with mock.patch.object(daemon_mod.Daemon, "serve"), \
             mock.patch.object(daemon_mod, "threading") as fake_threads:
            d.start()
        self.assertGreaterEqual(daemon_mod.age(daemon_mod.HEARTBEAT_PATH), 0)
        self.assertGreaterEqual(daemon_mod.age(daemon_mod.SSE_HEARTBEAT_PATH), 0)
        fake_threads.Thread.assert_called_once()


class TestWatchdog(unittest.TestCase):
    def test_file_age_missing_is_none(self):
        self.assertIsNone(watchdog_mod.file_age(os.path.join(HOME, "nope")))

    def test_file_age_reads_mtime(self):
        path = os.path.join(HOME, "hb-age")
        with open(path, "w") as f:
            f.write("x")
        os.utime(path, (time.time() - 100, time.time() - 100))
        self.assertAlmostEqual(watchdog_mod.file_age(path), 100, delta=2)

    def test_is_stale_fresh_old_missing(self):
        path = os.path.join(HOME, "hb-stale")
        daemon_mod.touch(path)
        self.assertFalse(watchdog_mod.is_stale(path, 120))
        os.utime(path, (time.time() - 300, time.time() - 300))
        self.assertTrue(watchdog_mod.is_stale(path, 120))
        self.assertTrue(watchdog_mod.is_stale(os.path.join(HOME, "gone"), 120))

    def test_decide_matrix(self):
        d = watchdog_mod.decide
        self.assertEqual(d(False, False, True, True), "skip-not-installed")
        self.assertEqual(d(True, False, True, True), "skip-not-loaded")
        self.assertEqual(d(True, True, True, False), "restart")
        self.assertEqual(d(True, True, False, True), "restart")
        self.assertEqual(d(True, True, True, True), "restart")
        self.assertEqual(d(True, True, False, False), "ok")


if __name__ == "__main__":
    unittest.main()
