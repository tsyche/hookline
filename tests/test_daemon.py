#!/usr/bin/env python3
"""Unit tests for the hookline daemon (stdlib only — no external deps).

Covers the session registry, phone-response routing (tmux injection vs
response-file), heartbeat staleness, and the watchdog's restart decision.

Run: /usr/bin/python3 -m unittest discover -s tests -p 'test_*.py'
"""

import importlib.machinery
import importlib.util
import json
import logging.handlers
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
        self.d.send_ntfy = lambda config, title, message, req_id, actions=None: \
            self.sent.append((title, message, req_id, actions)) or True

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

    def test_notify_forwards_custom_actions(self):
        actions = [{"label": "Alpha", "payload": "answer|Alpha"}]
        exchange(self.d, {"type": "notify", "session_id": "s1", "req_id": "r1",
                          "actions": actions})
        self.assertEqual(self.sent[0][3], actions)

    def test_notify_without_actions_passes_none(self):
        exchange(self.d, {"type": "notify", "session_id": "s1", "req_id": "r1"})
        self.assertIsNone(self.sent[0][3])

    def test_notify_no_actions_passes_empty_list(self):
        # notify-only question: explicit no_actions flag must suppress the
        # default trio (actions:[0] alone cannot — permissions send that too)
        exchange(self.d, {"type": "notify", "session_id": "s1", "req_id": "r1",
                          "actions": [], "no_actions": True})
        self.assertEqual(self.sent[0][3], [])

    def test_notify_stores_question_options(self):
        exchange(self.d, {"type": "notify", "session_id": "s1", "req_id": "r1",
                          "options": ["Alpha", "Beta"]})
        self.assertEqual(self.d.question_options["r1"], ["Alpha", "Beta"])

    def test_notify_supersede_clears_options(self):
        exchange(self.d, {"type": "notify", "session_id": "s1", "req_id": "r1",
                          "options": ["Alpha"]})
        exchange(self.d, {"type": "notify", "session_id": "s1", "req_id": "r2"})
        self.assertNotIn("r1", self.d.question_options)


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
        self.assertEqual(os.stat(rf).st_mode & 0o777, 0o600)
        self.assertNotIn("r1", self.d.pending)

    def test_retry_writes_retry_and_clears_pending(self):
        rf = os.path.join(HOME, "resp-retry")
        self.register(response_file=rf)
        self.d.handle_response("r1", "retry")
        with open(rf) as f:
            self.assertEqual(f.read(), "retry")
        self.assertNotIn("r1", self.d.pending)

    def test_answer_writes_answer_label_and_clears_pending(self):
        rf = os.path.join(HOME, "resp-answer")
        self.register(response_file=rf)
        with mock.patch.object(daemon_mod.subprocess, "run") as run:
            self.d.handle_response("r1", "answer|Alpha")
        run.assert_not_called()  # questions route via response file, never tmux
        with open(rf) as f:
            self.assertEqual(f.read(), "answer|Alpha")
        self.assertEqual(os.stat(rf).st_mode & 0o777, 0o600)
        self.assertNotIn("r1", self.d.pending)

    def test_answer_via_tmux_sends_option_number(self):
        self.register(tmux_pane="%1")
        self.d.question_options["r1"] = ["Alpha", "Beta", "Gamma"]
        with mock.patch.object(daemon_mod, "TMUX_BIN", "/usr/bin/tmux"), \
             mock.patch.object(daemon_mod.subprocess, "run") as run:
            run.return_value.returncode = 0
            self.d.handle_response("r1", "answer|Beta")
        run.assert_called_once_with(
            ["/usr/bin/tmux", "-S", "/tmp/t.sock", "send-keys", "-t", "%1", "2", "Enter"],
            capture_output=True,
        )
        self.assertNotIn("r1", self.d.pending)
        self.assertNotIn("r1", self.d.question_options)

    def test_unknown_req_id_is_ignored(self):
        with mock.patch.object(daemon_mod.subprocess, "run") as run:
            self.d.handle_response("nope", "allow")
        run.assert_not_called()
        self.assertEqual(self.d.pending, {})


class TestSendNtfyActions(unittest.TestCase):
    """ntfy payload buttons: default trio, or adapter-provided question options."""

    def send(self, actions=None):
        d = daemon_mod.Daemon()
        captured = {}

        def fake_urlopen(req, timeout=10):
            captured["payload"] = json.loads(req.data)

            class R:
                def read(self):
                    return json.dumps({"id": "nid"}).encode()

                def __enter__(self):
                    return self

                def __exit__(self, *exc):
                    return False

            return R()

        with mock.patch.object(d, "_throttle"), \
             mock.patch.object(daemon_mod.urllib.request, "urlopen", fake_urlopen):
            ok = d.send_ntfy({"HOOKLINE_TOPIC": "tp"}, "t", "m", "req1", actions)
        self.assertTrue(ok)
        return captured["payload"]

    def test_default_trio_when_actions_omitted(self):
        acts = self.send()["actions"]
        self.assertEqual([a["label"] for a in acts], ["Allow", "Deny", "Retry"])
        self.assertEqual(acts[0]["body"], "allow|req1")

    def test_custom_actions_carry_payload_and_req_id(self):
        acts = self.send([{"label": "Alpha", "payload": "answer|Alpha"}])["actions"]
        self.assertEqual(len(acts), 1)
        self.assertEqual(acts[0]["label"], "Alpha")
        self.assertEqual(acts[0]["body"], "answer|Alpha|req1")
        self.assertEqual(acts[0]["method"], "POST")

    def test_empty_actions_means_no_buttons(self):
        acts = self.send([])["actions"]
        self.assertEqual(acts, [])


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
        # two SSE listeners: response topic (buttons) + bare topic (typed replies)
        calls = fake_threads.Thread.call_args_list
        self.assertEqual(len(calls), 2, calls)
        self.assertEqual(calls[0].kwargs["args"], ("-response",))
        self.assertEqual(calls[1].kwargs["args"], ("",))


class FakeSseResponse:
    """Minimal stand-in for an SSE stream: connects, immediately ends."""

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def __iter__(self):
        return iter([])


def drive_sse(d, script, stop_after):
    """Run sse_listener with a scripted urlopen; returns (info, warning) lists.

    script[n] is returned by the nth urlopen call (or raised when it is an
    exception); the stop_after-th call sets d._stop so the loop exits.
    """
    info, warning = [], []
    calls = {"n": 0}

    def fake_urlopen(*args, **kwargs):
        n = calls["n"]
        calls["n"] += 1
        if n >= stop_after:
            d._stop.set()
        action = script[min(n, len(script) - 1)]
        if isinstance(action, BaseException):
            raise action
        return action

    with mock.patch.object(d.log, "info", side_effect=lambda m, *a, **k: info.append(m)), \
         mock.patch.object(d.log, "warning", side_effect=lambda m, *a, **k: warning.append(m)), \
         mock.patch.object(daemon_mod.time, "sleep"), \
         mock.patch.object(daemon_mod.urllib.request, "urlopen", fake_urlopen):
        d.sse_listener()
    return info, warning


class TestSseLogging(unittest.TestCase):
    """The daemon log records SSE state changes, not routine reconnects."""

    def test_idle_timeout_reconnects_silently(self):
        d = daemon_mod.Daemon()
        info, warning = drive_sse(d, [socket.timeout("timed out")], stop_after=3)
        self.assertEqual(info, [])
        self.assertEqual(warning, [])

    def test_clean_close_announces_connect_exactly_once(self):
        d = daemon_mod.Daemon()
        info, warning = drive_sse(d, [FakeSseResponse()], stop_after=3)
        connected = [m for m in info if "SSE connected" in m]
        self.assertEqual(len(connected), 1, info)
        self.assertEqual(warning, [])

    def test_error_streak_logs_one_warning_then_recovery(self):
        d = daemon_mod.Daemon()
        info, warning = drive_sse(
            d,
            [daemon_mod.urllib.error.URLError("down"), FakeSseResponse()],
            stop_after=4,
        )
        lost = [m for m in warning if "SSE lost" in m]
        self.assertEqual(len(lost), 1, warning)
        connected = [m for m in info if "SSE connected" in m]
        self.assertEqual(len(connected), 1, info)


class TestSseAnswerRouting(unittest.TestCase):
    """The response-topic body format answer|<label>|<req_id> parses back to
    decision='answer|<label>' with a clean req_id — rsplit from the right."""

    def test_answer_body_routes_with_label(self):
        d = daemon_mod.Daemon()
        handled = []

        class LineSse(FakeSseResponse):
            def __iter__(self):
                return iter([json.dumps(
                    {"message": "answer|Alpha|r1"}).encode()])

        class SyncThread:
            def __init__(self, target=None, args=(), daemon=False, **kw):
                self.target, self.args = target, args

            def start(self):
                self.target(*self.args)

        with mock.patch.object(d, "handle_response",
                               side_effect=lambda r, dec: handled.append((r, dec))), \
             mock.patch.object(daemon_mod.threading, "Thread", SyncThread):
            drive_sse(d, [LineSse()], stop_after=1)
        self.assertEqual(handled, [("r1", "answer|Alpha")])


class TestTypedReply(unittest.TestCase):
    """Bare replies from the ntfy app: option number/letter, retry/allow/deny
    words, and invalid-reply feedback. Ambiguous replies are dropped."""

    def setUp(self):
        self.d = daemon_mod.Daemon()
        self.handled = []
        self.sent = []   # (title, message, req_id, actions) via send_ntfy
        patcher = mock.patch.object(
            self.d, "send_ntfy",
            side_effect=lambda cfg, t, m, r, actions=None: (
                self.sent.append((t, m, r, actions)), True)[1],
        )
        patcher.start()
        self.addCleanup(patcher.stop)

    def arm(self, req="r1", session="s1",
            options=("One", "Two", "Three", "Four")):
        self.d.sessions[session] = {"response_file": "/tmp/r",
                                    "notify_title": "[label] question"}
        self.d.pending[req] = session
        self.d.question_options[req] = list(options)
        return mock.patch.object(
            self.d, "handle_response",
            side_effect=lambda r, dec: self.handled.append((r, dec)),
        )

    def test_numeric_reply_maps_to_label(self):
        with self.arm():
            self.d.handle_typed_reply("4")
        self.assertEqual(self.handled, [("r1", "answer|Four")])

    def test_letter_reply_case_insensitive(self):
        with self.arm():
            self.d.handle_typed_reply("d")
        self.assertEqual(self.handled, [("r1", "answer|Four")])

    def test_reply_one_maps_to_first_label(self):
        with self.arm(options=("Alpha", "Beta", "Gamma")):
            self.d.handle_typed_reply("1")
        self.assertEqual(self.handled, [("r1", "answer|Alpha")])

    def test_out_of_range_gets_feedback_and_keeps_pending(self):
        with self.arm():
            for text in ("9", "0", "Z", "12", "hi", "", "1a"):
                self.d.handle_typed_reply(text)
        self.assertEqual(self.handled, [])
        self.assertIn("r1", self.d.pending)  # nothing consumed
        # empty string is not an attempt — every other miss pushes feedback
        self.assertEqual(len(self.sent), 6)
        title, msg, req, actions = self.sent[0]
        self.assertIn("invalid reply", title)
        self.assertIn("Reply 1-4 (or A-D)", msg)
        self.assertEqual(req, "r1")
        self.assertEqual([a["payload"] for a in actions], ["retry", "deny"])

    def test_word_guess_two_gets_feedback(self):
        with self.arm():
            self.d.handle_typed_reply("two")
        self.assertEqual(self.handled, [])
        self.assertEqual(len(self.sent), 1)   # feedback, not resolution
        self.assertIn("r1", self.d.pending)

    def test_word_guess_without_question_is_silent(self):
        self.d.sessions["s1"] = {"response_file": "/tmp/r"}
        self.d.pending["r1"] = "s1"
        self.d.handle_typed_reply("two")
        self.assertEqual(self.handled, [])
        self.assertEqual(self.sent, [])

    def test_retry_routes_to_single_pending(self):
        with self.arm():
            self.d.handle_typed_reply("retry")
        self.assertEqual(self.handled, [("r1", "retry")])

    def test_deny_routes_to_single_pending(self):
        with self.arm():
            self.d.handle_typed_reply("deny")
        self.assertEqual(self.handled, [("r1", "deny")])

    def test_allow_routes_to_permission_prompt(self):
        self.d.sessions["s1"] = {"response_file": "/tmp/r"}
        self.d.pending["r1"] = "s1"
        with mock.patch.object(
            self.d, "handle_response",
            side_effect=lambda r, dec: self.handled.append((r, dec)),
        ):
            self.d.handle_typed_reply("allow")
        self.assertEqual(self.handled, [("r1", "allow")])

    def test_allow_on_question_gets_feedback(self):
        with self.arm():
            self.d.handle_typed_reply("allow")
        self.assertEqual(self.handled, [])    # a question cannot be allowed
        self.assertEqual(len(self.sent), 1)
        self.assertIn("r1", self.d.pending)

    def test_word_reply_needs_exactly_one_pending(self):
        with self.arm():
            self.d.sessions["s2"] = {"response_file": "/tmp/r2"}
            self.d.pending["r2"] = "s2"
            self.d.handle_typed_reply("retry")
            self.d.handle_typed_reply("deny")
        self.assertEqual(self.handled, [])
        self.assertEqual(self.sent, [])

    def test_two_questions_pending_ambiguous_ignored(self):
        p1 = self.arm()
        with p1:
            self.d.sessions["s2"] = {"response_file": "/tmp/r2"}
            self.d.pending["r2"] = "s2"
            self.d.question_options["r2"] = ["Yes", "No"]
            self.d.handle_typed_reply("4")
        self.assertEqual(self.handled, [])
        self.assertEqual(self.sent, [])       # ambiguous — no feedback either

    def test_permission_prompt_ignored(self):
        # no options stored (permission notify) → nothing to resolve against
        self.d.sessions["s1"] = {"response_file": "/tmp/r"}
        self.d.pending["r1"] = "s1"
        self.d.handle_typed_reply("1")
        self.assertEqual(self.handled, [])
        self.assertEqual(self.sent, [])       # not a question — stay silent

    def test_resolution_clears_pending_and_options(self):
        self.d.sessions["s1"] = {"response_file": "/tmp/r"}
        self.d.pending["r1"] = "s1"
        self.d.question_options["r1"] = ["One", "Two"]
        with mock.patch.object(self.d, "_write_response") as wr:
            self.d.handle_typed_reply("2")
        wr.assert_called_once_with("/tmp/r", "answer|Two")
        self.assertEqual(self.d.pending, {})
        self.assertEqual(self.d.question_options, {})

    def test_sse_bare_body_dispatches_typed_reply(self):
        seen = []
        self._drive_sse_bodies(["D", "retry", "two", "12"], seen)
        self.assertEqual(seen, ["D", "retry", "two", "12"])

    def test_sse_ignores_notification_echo_bodies(self):
        seen = []
        self._drive_sse_bodies(
            ["[label] question — Pick one\n1. Alpha: a",
             "No response after 900s — agent waiting",
             "{}"],
            seen,
        )
        self.assertEqual(seen, [])

    def _drive_sse_bodies(self, bodies, seen):
        class LineSse(FakeSseResponse):
            def __iter__(self_inner):
                return iter([json.dumps({"message": b}).encode() for b in bodies])

        class SyncThread:
            def __init__(self, target=None, args=(), daemon=False, **kw):
                self.target, self.args = target, args

            def start(self):
                self.target(*self.args)

        with mock.patch.object(self.d, "handle_typed_reply",
                               side_effect=lambda t: seen.append(t)), \
             mock.patch.object(daemon_mod.threading, "Thread", SyncThread):
            drive_sse(self.d, [LineSse()], stop_after=1)


class TestLogRotation(unittest.TestCase):
    def test_log_file_is_capped_with_one_backup(self):
        d = daemon_mod.Daemon()
        self.assertEqual(len(d.log.handlers), 1)
        handler = d.log.handlers[0]
        self.assertIsInstance(handler, logging.handlers.RotatingFileHandler)
        self.assertEqual(handler.maxBytes, daemon_mod.LOG_MAX_BYTES)
        # ~10KB records: ~960KB total must roll over into daemon.log.1
        for _ in range(96):
            d.log.info("rotation-probe " + "x" * 10240)
        handler.flush()
        active = os.path.getsize(daemon_mod.LOG_PATH)
        backup = daemon_mod.LOG_PATH + ".1"
        self.assertLessEqual(active, daemon_mod.LOG_MAX_BYTES + 16 * 1024)
        self.assertTrue(os.path.exists(backup), "no rotated backup created")
        self.assertGreater(os.path.getsize(backup), 0)


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
