#!/usr/bin/env bun
/** Remote control HTTP server for NixOS + Niri. */

import { createHash, timingSafeEqual } from "node:crypto";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import { join } from "node:path";

const MAX_BODY_BYTES = 1024 * 1024;
const REQUEST_TIMEOUT_SECONDS = 15;
const REQUEST_TIMEOUT_MS = REQUEST_TIMEOUT_SECONDS * 1000;
const MAX_CONCURRENT_REQUESTS = 16;

const PORT = 8901;
const USERNAME = "@username@";
const LAN_ADDRESS = "@lanAddress@";
const RUNTIME_DIRECTORY_PATH = "@runtimeDirectoryPath@";

const WLCOPY = "@wlClipboard@/bin/wl-copy";
const WLPASTE = "@wlClipboard@/bin/wl-paste";
const NIRI = "@niri@/bin/niri";
const NOCTALIA = "@noctalia@/bin/noctalia";

const credentialDir = process.env.CREDENTIALS_DIRECTORY;
if (!credentialDir) throw new Error("CREDENTIALS_DIRECTORY is not set");

const TOKEN = (await Bun.file(join(credentialDir, "token")).text()).trim();
if (!TOKEN) throw new Error("remote-control token is empty");

// Hash first so timingSafeEqual always compares equal-length buffers.
const TOKEN_DIGEST = createHash("sha256").update(TOKEN).digest();

const COMMON_HEADERS = {
  "Cache-Control": "no-store",
  "X-Content-Type-Options": "nosniff",
} as const;

type Env = Record<string, string | undefined>;
type RouteHandler = (req: Request) => Response | Promise<Response>;
type RunOptions = { env?: Env; uid?: number; gid?: number };
type RunResult = {
  ok: boolean;
  stdout: string;
  error: string;
  timedOut: boolean;
  exitCode: number;
};

function json(status: number, data: unknown): Response {
  return Response.json(data, { status, headers: COMMON_HEADERS });
}

function binary(status: number, contentType: string, data: Uint8Array): Response {
  return new Response(data, {
    status,
    headers: { ...COMMON_HEADERS, "Content-Type": contentType },
  });
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function authorized(req: Request): boolean {
  const digest = createHash("sha256")
    .update(req.headers.get("authorization") ?? "")
    .digest();
  return timingSafeEqual(digest, TOKEN_DIGEST);
}

async function run(cmd: string[], options: RunOptions = {}): Promise<RunResult> {
  let proc: Bun.Subprocess<"ignore", "pipe", "pipe">;
  try {
    proc = Bun.spawn({
      cmd,
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
      env: options.env,
      uid: options.uid,
      gid: options.gid,
      timeout: REQUEST_TIMEOUT_MS,
      killSignal: "SIGKILL",
    });
  } catch (error) {
    return {
      ok: false,
      stdout: "",
      error: `failed to spawn command: ${message(error)}`,
      timedOut: false,
      exitCode: -1,
    };
  }

  const [stdout, stderr, exitCode] = await Promise.all([
    proc.stdout.text(),
    proc.stderr.text(),
    proc.exited,
  ]);
  const timedOut = proc.signalCode === "SIGKILL";

  return {
    ok: exitCode === 0 && !timedOut,
    stdout,
    error: timedOut ? "command timed out" : stderr.trim(),
    timedOut,
    exitCode,
  };
}

async function resolveUser(username: string) {
  const result = await run(["getent", "passwd", username]);
  if (!result.ok) {
    throw new Error(
      `could not resolve user ${username}: ${result.error || `getent exited ${result.exitCode}`}`,
    );
  }

  const fields = (result.stdout.trim().split("\n", 1)[0] ?? "").split(":");
  const uid = Number(fields[2]);
  const gid = Number(fields[3]);
  const home = fields[5] ?? "";

  if (
    fields.length < 7 ||
    !Number.isSafeInteger(uid) ||
    uid < 0 ||
    !Number.isSafeInteger(gid) ||
    gid < 0 ||
    !home
  ) {
    throw new Error(`could not resolve user ${username}: malformed passwd entry`);
  }

  return { uid, gid, home };
}

const TARGET_USER = await resolveUser(USERNAME);

async function waylandSession(): Promise<Required<Pick<RunOptions, "uid" | "gid">> & { env: Env }> {
  const runtimeDir = `/run/user/${TARGET_USER.uid}`;
  let waylandDisplay = "wayland-0";
  let niriSocket: string | undefined;

  try {
    const names = (await readdir(runtimeDir)).sort();
    waylandDisplay =
      names.find((name) => name.startsWith("wayland-") && !name.endsWith(".lock")) ??
      waylandDisplay;
    const socket = names.find((name) => name.startsWith("niri.") && name.endsWith(".sock"));
    if (socket) niriSocket = join(runtimeDir, socket);
  } catch {
    // Match the Python fallback behavior.
  }

  const env: Env = {
    WAYLAND_DISPLAY: waylandDisplay,
    XDG_RUNTIME_DIR: runtimeDir,
    DBUS_SESSION_BUS_ADDRESS: `unix:path=/run/user/${TARGET_USER.uid}/bus`,
    HOME: TARGET_USER.home,
    ...(niriSocket ? { NIRI_SOCKET: niriSocket } : {}),
  };

  return { env, uid: TARGET_USER.uid, gid: TARGET_USER.gid };
}

async function runAction(
  cmd: string[],
  okStatus: string,
  options: RunOptions = {},
): Promise<Response> {
  const result = await run(cmd, options);
  return result.ok
    ? json(200, { status: okStatus })
    : json(500, {
        status: "error",
        ...(result.error ? { detail: result.error } : {}),
      });
}

function parseProperties(output: string): Record<string, string> {
  return Object.fromEntries(
    output
      .trim()
      .split("\n")
      .map((line) => {
        const at = line.indexOf("=");
        return at === -1 ? null : [line.slice(0, at), line.slice(at + 1)];
      })
      .filter((entry): entry is [string, string] => entry !== null),
  );
}

async function getPing() {
  return json(200, { status: "ok" });
}

async function getStatus() {
  const listed = await run(["loginctl", "list-sessions", "--no-legend"]);
  if (listed.timedOut) return json(504, { error: "loginctl timed out" });
  if (!listed.ok) {
    return json(500, {
      status: "error",
      detail: listed.error || `loginctl exited ${listed.exitCode}`,
    });
  }

  const ids = listed.stdout
    .trim()
    .split("\n")
    .map((line) => line.trim().split(/\s+/, 1)[0])
    .filter((id): id is string => Boolean(id));

  const results = await Promise.all(
    ids.map(async (id) => ({
      id,
      result: await run([
        "loginctl",
        "show-session",
        id,
        "-p",
        "LockedHint",
        "-p",
        "Name",
        "-p",
        "Type",
      ]),
    })),
  );

  if (results.some(({ result }) => result.timedOut)) {
    return json(504, { error: "loginctl timed out" });
  }

  const sessions = results.flatMap(({ id, result }) => {
    if (!result.ok && !result.stdout.trim()) return [];
    const props = parseProperties(result.stdout);
    if (!Object.keys(props).length) return [];
    return [{
      id,
      locked: props.LockedHint === "yes",
      user: props.Name ?? "",
      type: props.Type ?? "",
    }];
  });

  return json(200, { sessions });
}

async function getClipboard() {
  const result = await run([WLPASTE], await waylandSession());
  if (result.timedOut) return json(504, { error: "clipboard read timed out" });
  return result.ok
    ? json(200, { text: result.stdout })
    : json(500, { status: "error", detail: result.error });
}

async function getScreenshot() {
  const session = await waylandSession();
  const tmpDir = await mkdtemp(join(RUNTIME_DIRECTORY_PATH, "screenshot-"));
  const tmpPath = join(tmpDir, "screenshot.png");

  try {
    const result = await run(
      [NIRI, "msg", "action", "screenshot-screen", "--path", tmpPath],
      session,
    );

    if (result.timedOut) return json(504, { error: "screenshot timed out" });
    if (!result.ok) {
      return json(500, {
        status: "error",
        detail: `niri screenshot failed: ${result.error}`,
      });
    }

    try {
      return binary(200, "image/png", await Bun.file(tmpPath).bytes());
    } catch (error) {
      return json(500, {
        status: "error",
        detail: `could not read screenshot: ${message(error)}`,
      });
    }
  } finally {
    await rm(tmpDir, { recursive: true, force: true }).catch(() => {});
  }
}

async function postClipboard(req: Request) {
  const body = new Uint8Array(await req.arrayBuffer());
  if (!body.byteLength) return json(400, { error: "empty body" });
  if (body.byteLength > MAX_BODY_BYTES) {
    return json(413, { error: "body exceeds 1 MiB" });
  }

  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(body);
  } catch {
    return json(400, { error: "body must be UTF-8" });
  }
  if (!text) return json(400, { error: "empty body" });

  const session = await waylandSession();
  let proc: Bun.Subprocess<Blob, "ignore", "ignore">;

  try {
    // Use stdin rather than argv so a <=1 MiB body cannot hit Linux ARG_MAX.
    proc = Bun.spawn({
      cmd: [WLCOPY, "--"],
      stdin: new Blob([body]),
      stdout: "ignore",
      stderr: "ignore",
      detached: true,
      env: session.env,
      uid: session.uid,
      gid: session.gid,
      timeout: REQUEST_TIMEOUT_MS,
      killSignal: "SIGKILL",
    });
  } catch (error) {
    return json(500, {
      status: "error",
      detail: `failed to start wl-copy: ${message(error)}`,
    });
  }

  const exitCode = await proc.exited;
  if (proc.signalCode === "SIGKILL") {
    return json(504, { error: "clipboard write timed out" });
  }
  return exitCode === 0
    ? json(200, { status: "copied", length: [...text].length })
    : json(500, { status: "error", detail: `wl-copy exited ${exitCode}` });
}

async function postLock() {
  const session = await waylandSession();
  return runAction([NOCTALIA, "msg", "session", "lock"], "locked", session);
}

async function postUnlock() {
  const session = await waylandSession();
  const unlock = await run(["loginctl", "unlock-sessions"], session);
  const wake = await run([NIRI, "msg", "action", "power-on-monitors"], session);
  const ok = unlock.ok && wake.ok;

  return json(ok ? 200 : 500, {
    status: ok ? "unlocked" : "error",
    ...(!ok
      ? { detail: unlock.error || wake.error || `command failed (${unlock.exitCode}, ${wake.exitCode})` }
      : {}),
  });
}

const postShutdown = () => runAction(["systemctl", "poweroff"], "shutting down");
const postReboot = () => runAction(["systemctl", "reboot"], "rebooting");

let activeRequests = 0;

function log(req: Request, response: Response) {
  console.log(`${req.method} ${new URL(req.url).pathname} ${response.status}`);
}

function guarded(handler: RouteHandler): RouteHandler {
  return async (req) => {
    if (!authorized(req)) {
      const response = json(401, { error: "unauthorized" });
      log(req, response);
      return response;
    }
    if (activeRequests >= MAX_CONCURRENT_REQUESTS) {
      const response = json(503, { error: "server busy" });
      log(req, response);
      return response;
    }

    activeRequests++;
    try {
      const response = await handler(req);
      log(req, response);
      return response;
    } catch (error) {
      console.error("request handler failed:", error);
      const response = json(500, { error: "internal server error" });
      log(req, response);
      return response;
    } finally {
      activeRequests--;
    }
  };
}

const server = Bun.serve({
  hostname: LAN_ADDRESS,
  port: PORT,
  idleTimeout: REQUEST_TIMEOUT_SECONDS,
  maxRequestBodySize: MAX_BODY_BYTES,
  development: false,

  routes: {
    "/ping": { GET: guarded(getPing) },
    "/status": { GET: guarded(getStatus) },
    "/clipboard": {
      GET: guarded(getClipboard),
      POST: guarded(postClipboard),
    },
    "/screenshot": { GET: guarded(getScreenshot) },
    "/lock": { POST: guarded(postLock) },
    "/unlock": { POST: guarded(postUnlock) },
    "/shutdown": { POST: guarded(postShutdown) },
    "/reboot": { POST: guarded(postReboot) },
  },

  fetch: guarded(() => json(404, { error: "not found" })),
  error(error) {
    console.error("server error:", error);
    return json(500, { error: "internal server error" });
  },
});

console.log(`remote-control listening on ${server.url}`);
