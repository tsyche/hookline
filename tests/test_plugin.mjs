// Unit tests for hooks/plugins/hookline.js (node --test).
//
// Sandboxed: HOME is redirected to a temp dir BEFORE the plugin module is
// imported, so every homedir()-derived path (data dir, log, reply socket,
// counter files) lands in the sandbox. A fake hook script captures what the
// plugin spawns (stdin payload + reply-bridge env); a fake SDK client records
// bridge replies. No network, no opencode, no real hook execution.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
  existsSync,
  copyFileSync,
} from "node:fs";
import { join, dirname } from "node:path";import { fileURLToPath } from "node:url";
import { connect } from "node:net";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "..");

// ── sandbox: must be set before the plugin module loads ──────────────────────
// Short path: the reply socket binds a unix path (macOS sun_path limit 104),
// so the sandbox HOME must live under /tmp, not the long /var/folders prefix.
const HOME = mkdtempSync(join("/tmp", "hlp-"));
process.env.HOME = HOME;
const DATA_DIR = join(HOME, ".local/share/hookline");
mkdirSync(DATA_DIR, { recursive: true });

const CAPTURE = join(HOME, "spawn-capture.txt");
const FAKE_HOOK = join(HOME, "fake-hook.sh");
writeFileSync(
  FAKE_HOOK,
  `#!/bin/bash
cat > "$HOOK_TEST_CAPTURE"
printf '\\n%s\\n' "$HOOKLINE_OPC_REPLY_SOCK" >> "$HOOK_TEST_CAPTURE"
printf '%s\\n' "$HOOKLINE_OPC_SERVER" >> "$HOOK_TEST_CAPTURE"
printf '%s\\n' "$HOOKLINE_OPC_CWD" >> "$HOOK_TEST_CAPTURE"
`,
  { mode: 0o755 },
);
process.env.HOOKLINE_HOOK = FAKE_HOOK;
process.env.HOOK_TEST_CAPTURE = CAPTURE;

// import the plugin as ESM regardless of its .js extension (repo package.json
// sets type:module — copy is belt-and-braces for running outside the repo)
const PLUGIN = join(REPO, "hooks/plugins/hookline.js");
const PLUGIN_COPY = join(HOME, "hookline-plugin.mjs");
copyFileSync(PLUGIN, PLUGIN_COPY);
const { Hookline } = await import(PLUGIN_COPY);

// ── helpers ──────────────────────────────────────────────────────────────────
const waitFor = async (fn, ms = 4000) => {
  const t0 = Date.now();
  for (;;) {
    if (await fn()) return;
    if (Date.now() - t0 > ms) throw new Error("waitFor timeout");
    await new Promise((r) => setTimeout(r, 25));
  }
};

const readCapture = () => {
  // fake hook: `cat > file` (payload, no newline), then \n<sock>\n, server, cwd
  const parts = readFileSync(CAPTURE, "utf8").split("\n");
  return {
    payload: JSON.parse(parts[0]),
    replySock: parts[1] ?? "",
    server: parts[2] ?? "",
    cwd: parts[3] ?? "",
  };
};

const calls = [];
const client = {
  postSessionIdPermissionsPermissionId: async (args) => {
    calls.push({ kind: "permission", args });
    return { data: { ok: true } };
  },
  question: {
    reply: async (args) => {
      calls.push({ kind: "question.reply", args });
      return { data: { ok: true } };
    },
    reject: async (args) => {
      calls.push({ kind: "question.reject", args });
      return { data: { ok: true } };
    },
  },
};

const REPLY_SOCK = join(DATA_DIR, `opc-reply-${process.pid}.sock`);

const sendBridge = (msg) => {
  const s = connect(REPLY_SOCK);
  s.on("connect", () => s.end(JSON.stringify(msg)));
  s.on("error", () => {}); // server may FIN first — replies are asserted via `calls`
};

let hookline;

before(async () => {
  hookline = await Hookline({
    client,
    serverUrl: "http://localhost:4096",
    directory: "/proj",
  });
});

after(async () => {
  await hookline?.dispose?.();
});

// ── event routing: spawn ─────────────────────────────────────────────────────

test("permission.asked spawns the hook with the payload on stdin", async () => {
  writeFileSync(CAPTURE, "");
  await hookline.event({
    event: {
      type: "permission.asked",
      properties: { sessionID: "s-perm", id: "per_1", permission: "bash" },
    },
  });
  // wait for the LAST line (cwd) — payload alone would race the printf lines
  await waitFor(() => existsSync(CAPTURE) && readFileSync(CAPTURE, "utf8").includes("/proj"));
  const cap = readCapture();
  assert.equal(cap.payload.id, "per_1");
  assert.equal(cap.payload.permission, "bash");
  assert.equal(cap.replySock, REPLY_SOCK);
  assert.equal(cap.server, "http://localhost:4096");
  assert.equal(cap.cwd, "/proj");
});

test("question.asked spawns the hook with the question payload", async () => {
  writeFileSync(CAPTURE, "");
  await hookline.event({
    event: {
      type: "question.asked",
      properties: {
        sessionID: "s-q",
        id: "que_1",
        questions: [{ question: "Ship it?", options: [{ label: "Yes" }] }],
      },
    },
  });
  await waitFor(() => existsSync(CAPTURE) && readFileSync(CAPTURE, "utf8").includes("/proj"));
  const cap = readCapture();
  assert.equal(cap.payload.questions[0].question, "Ship it?");
  assert.equal(cap.replySock, REPLY_SOCK);
});

// ── event routing: local-answer counter ──────────────────────────────────────

// counter file grows by one EMPTY line per local answer (the hook's progress
// signal is `wc -l`), so count newlines, not non-empty entries
const counterLines = (f) => (readFileSync(f, "utf8").match(/\n/g) ?? []).length;

test("permission.replied appends one counter line per event", async () => {
  const counter = join(DATA_DIR, "opencode-answered-s-count");
  await hookline.event({
    event: { type: "permission.replied", properties: { sessionID: "s-count" } },
  });
  await hookline.event({
    event: { type: "permission.replied", properties: { sessionID: "s-count" } },
  });
  await waitFor(() => existsSync(counter) && counterLines(counter) >= 2);
  assert.equal(counterLines(counter), 2);
});

test("question.rejected appends to the same counter file", async () => {
  const counter = join(DATA_DIR, "opencode-answered-s-count");
  const before = counterLines(counter);
  await hookline.event({
    event: { type: "question.rejected", properties: { sessionID: "s-count" } },
  });
  await waitFor(() => counterLines(counter) > before);
  assert.equal(counterLines(counter), before + 1);
});

// ── reply bridge ─────────────────────────────────────────────────────────────

test("bridge permission reply posts the response to the SDK client", async () => {
  const n = calls.length;
  sendBridge({ session_id: "s-perm", permission_id: "per_9", response: "once" });
  await waitFor(() => calls.length > n);
  const call = calls[n];
  assert.equal(call.kind, "permission");
  assert.deepEqual(call.args, {
    path: { id: "s-perm", permissionID: "per_9" },
    body: { response: "once" },
  });
});

test("bridge question reply wraps answers and passes requestID", async () => {
  const n = calls.length;
  sendBridge({ type: "question", request_id: "que_9", answers: ["Green"] });
  await waitFor(() => calls.length > n);
  const call = calls[n];
  assert.equal(call.kind, "question.reply");
  assert.deepEqual(call.args, {
    requestID: "que_9",
    directory: "/proj",
    answers: [["Green"]],
  });
});

test("bridge question-reject calls question.reject", async () => {
  const n = calls.length;
  sendBridge({ type: "question-reject", request_id: "que_10" });
  await waitFor(() => calls.length > n);
  const call = calls[n];
  assert.equal(call.kind, "question.reject");
  assert.equal(call.args.requestID, "que_10");
  assert.equal(call.args.directory, "/proj");
});

// ── lifecycle ────────────────────────────────────────────────────────────────

test("dispose closes the reply socket", async () => {
  await hookline.dispose();
  await new Promise((resolve) => {
    const s = connect(REPLY_SOCK);
    s.on("connect", () => {
      s.destroy();
      resolve();
    });
    s.on("error", () => resolve()); // refused/unlink — expected after dispose
    setTimeout(() => resolve(), 1000);
  });
  assert.equal(existsSync(REPLY_SOCK), false);
});
