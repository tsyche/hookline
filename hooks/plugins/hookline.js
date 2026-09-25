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
//
// Decisions travel the other way over a unix socket: the opencode SDK client
// reached from this plugin is the only party that can actually answer a
// prompt — its transport does not resolve serverUrl over TCP (plain curl to
// the same URL gets ECONNREFUSED). The plugin listens on
// $HOOKLINE_OPC_REPLY_SOCK and POSTs {response: once|always|reject} via
// client.postSessionIdPermissionsPermissionId.
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
        const r = await client.postSessionIdPermissionsPermissionId({
          path: { id: msg.session_id, permissionID: msg.permission_id },
          body: { response: msg.response },
        });
        logLine(
          `replied ${msg.response} (${msg.permission_id}) → ${JSON.stringify(r.data)}`,
        );
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

  return {
    dispose: async () => {
      try {
        replyServer.close();
        unlinkSync(REPLY_SOCK);
      } catch {}
    },
    event: async ({ event }) => {
      if (event.type === "permission.asked") {
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
          child.stdin.write(JSON.stringify(event.properties));
          child.stdin.end();
          child.on("error", (err) => logLine(`spawn error: ${err}`));
        } catch (err) {
          logLine(`spawn threw: ${err}`);
        }
      }

      if (event.type === "permission.replied") {
        try {
          appendFileSync(
            join(DATA_DIR, `opencode-answered-${event.properties.sessionID}`),
            "\n",
          );
        } catch {
          // counter dir missing — progress signal degrades to "never grows"
        }
      }
    },
  };
};
