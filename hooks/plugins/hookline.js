// hookline opencode plugin — thin event router + reply bridge for OpenCode.
//
// Installed by install.sh to ~/.config/opencode/plugins/hookline.js (opencode
// auto-loads that directory; no opencode.jsonc edit, no config clobber).
//
// Contract:
//   permission.asked   → spawn `hookline.sh opencode` with the permission
//                        object on stdin. The native TUI prompt is already
//                        showing; the hook runs the provider-neutral core
//                        (grace period, allowlist, daemon/ntfy phone flow).
//   permission.replied → append a line to the per-session counter file; the
//                        hook's progress signal sees growth and tears down
//                        its background flow (local or programmatic answer).
//   question.asked / question.v2.asked  → same spawn; stdin carries the
//                        question payload (questions[] + options instead of a
//                        permission). The native question dialog is showing.
//   question.replied / question.rejected (+ .v2) → same counter-file append:
//                        answering or dismissing the dialog at the terminal
//                        cancels the hook's grace/notification flow.
//
// Decisions travel the other way over a unix socket: the opencode SDK client
// reached from this plugin is the only party that can actually answer a
// prompt — its transport does not resolve serverUrl over TCP (plain curl to
// the same URL gets ECONNREFUSED; the client dispatches through an in-process
// fetch when opencode runs without an HTTP listener). The plugin listens on
// $HOOKLINE_OPC_REPLY_SOCK and POSTs:
//   {response, session_id, permission_id}   → client.postSessionIdPermissionsPermissionId
//   {type:"question", request_id, answers}  → question.reply (answers wrapped per-question)
//   {type:"question-reject", request_id}    → question.reject
//
// The injected client is the v1 SDK surface (no `question` API), so question
// calls go through a lazily built v2 client that reuses the injected client's
// own transport (getConfig(): fetch/baseUrl/headers) — a fresh client with
// default fetch would try plain TCP and get ECONNREFUSED.
//
// Child env: HOOKLINE_OPC_REPLY_SOCK (this socket), HOOKLINE_OPC_SERVER
// (informational serverUrl), HOOKLINE_OPC_CWD (project directory — the
// permission payload has no cwd).

import { appendFileSync, existsSync, openSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { createServer } from "node:net";

const HOOK = [
  process.env.HOOKLINE_HOOK,
  join(homedir(), ".local/share/hookline/hooks/hookline.sh"),
  join(homedir(), "Repos/hookline/hooks/hookline.sh"),
].find((p) => p && existsSync(p));

const DATA_DIR = join(homedir(), ".local/share/hookline");
const LOG_FILE = join(DATA_DIR, "hookline.log");
const REPLY_SOCK = join(DATA_DIR, `opc-reply-${process.pid}.sock`);

const logLine = (msg) => {
  try {
    appendFileSync(LOG_FILE, `[plugin] ${msg}\n`);
  } catch {}
};

export const Hookline = async ({ client, serverUrl, directory }) => {
  if (!HOOK) return {}; // hookline not installed — inert plugin

  const logFd = (() => {
    try {
      return openSync(LOG_FILE, "a");
    } catch {
      return "ignore";
    }
  })();

  // Reply bridge: hook process → here → opencode permission API.
  try {
    unlinkSync(REPLY_SOCK);
  } catch {}
  const replyServer = createServer((sock) => {
    let buf = "";
    sock.on("data", (d) => (buf += d));
    sock.on("error", () => {});
    sock.on("end", async () => {
      try {
        const msg = JSON.parse(buf);
        if (msg.type === "question") {
          // v2 transport: injected client may carry `question` itself (future
          // opencode); otherwise rebuild one over its getConfig() transport.
          const qc = client.question?.reply ? client : await questionClient();
          const r = await qc.question.reply({
            requestID: msg.request_id,
            directory,
            answers: [msg.answers],
          });
          logLine(
            `question replied ${JSON.stringify(msg.answers)} (${msg.request_id}) → ${JSON.stringify(r.data)}`,
          );
        } else if (msg.type === "question-reject") {
          const qc = client.question?.reject ? client : await questionClient();
          const r = await qc.question.reject({
            requestID: msg.request_id,
            directory,
          });
          logLine(
            `question rejected (${msg.request_id}) → ${JSON.stringify(r.data)}`,
          );
        } else {
          const r = await client.postSessionIdPermissionsPermissionId({
            path: { id: msg.session_id, permissionID: msg.permission_id },
            body: { response: msg.response },
          });
          logLine(
            `replied ${msg.response} (${msg.permission_id}) → ${JSON.stringify(r.data)}`,
          );
        }
        sock.end("ok");
      } catch (e) {
        logLine(`reply failed: ${String(e).slice(0, 300)}`);
        try {
          sock.end("err");
        } catch {}
      }
    });
  });
  await new Promise((resolve) => {
    replyServer.once("error", (e) => logLine(`reply sock error: ${e}`));
    replyServer.listen(REPLY_SOCK, resolve);
  });
  logLine(`loaded serverUrl=${String(serverUrl)} sock=${REPLY_SOCK} cwd=${directory}`);

  // v2 question client — reuses the injected client's transport (in-process
  // fetch / baseUrl / headers) so replies reach the server without TCP.
  let qClientP = null;
  const questionClient = () => {
    if (!qClientP) {
      qClientP = (async () => {
        const raw = client?._client;
        const cfg = raw?.getConfig?.() ?? {};
        const headers =
          cfg.headers instanceof Headers
            ? Object.fromEntries(cfg.headers.entries())
            : cfg.headers;
        const { createOpencodeClient } = await import("@opencode-ai/sdk/v2");
        const qc = createOpencodeClient({
          ...cfg,
          headers,
          baseUrl: cfg.baseUrl ?? String(serverUrl),
          directory,
        });
        logLine(
          `question client: v2 transport=${cfg.fetch ? "injected" : "serverUrl"}`,
        );
        return qc;
      })().catch((e) => {
        qClientP = null; // retry next time rather than caching the failure
        throw e;
      });
    }
    return qClientP;
  };

  return {
    dispose: async () => {
      try {
        replyServer.close();
        unlinkSync(REPLY_SOCK);
      } catch {}
    },
    event: async ({ event }) => {
      const spawnHook = (properties) => {
        try {
          const child = spawn(HOOK, ["opencode"], {
            env: {
              ...process.env,
              HOOKLINE_OPC_REPLY_SOCK: REPLY_SOCK,
              HOOKLINE_OPC_SERVER: String(serverUrl),
              HOOKLINE_OPC_CWD: directory,
            },
            stdio: ["pipe", "ignore", logFd],
          });
          child.stdin.write(JSON.stringify(properties));
          child.stdin.end();
          child.on("error", (err) => logLine(`spawn error: ${err}`));
        } catch (err) {
          logLine(`spawn threw: ${err}`);
        }
      };

      const appendCounter = (sessionID) => {
        try {
          appendFileSync(
            join(DATA_DIR, `opencode-answered-${sessionID}`),
            "\n",
          );
        } catch {
          // counter dir missing — progress signal degrades to "never grows"
        }
      };

      if (
        event.type === "permission.asked" ||
        event.type === "question.asked" ||
        event.type === "question.v2.asked"
      ) {
        spawnHook(event.properties);
      }

      if (
        event.type === "permission.replied" ||
        event.type === "question.replied" ||
        event.type === "question.rejected" ||
        event.type === "question.v2.replied" ||
        event.type === "question.v2.rejected"
      ) {
        appendCounter(event.properties.sessionID);
      }
    },
  };
};
