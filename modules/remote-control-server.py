#!/usr/bin/env python3
"""Remote control HTTPS server for NixOS + Niri.

Endpoints:
  GET  /ping        — health check
  GET  /status      — show session lock state
  GET  /clipboard   — read clipboard
  GET  /screenshot  — capture focused screen and return PNG
  POST /lock        — lock all sessions
  POST /unlock      — unlock all sessions and wake monitors
  POST /clipboard   — set clipboard (send text as raw body)
  POST /shutdown    — power off
  POST /reboot      — reboot

Auth: Bearer token via Authorization header.
The token is supplied through systemd credentials.
"""

import http.server
import hmac
import json
import pwd
import os
import socketserver
import ssl
import subprocess
import tempfile
import threading
from pathlib import Path
from urllib.parse import urlparse

MAX_BODY_BYTES = 1024 * 1024
REQUEST_TIMEOUT_SECONDS = 15
MAX_REQUEST_THREADS = 16


class BoundedThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    request_queue_size = MAX_REQUEST_THREADS

    def __init__(self, *args, tls_context, **kwargs):
        self._tls_context = tls_context
        self._request_slots = threading.BoundedSemaphore(MAX_REQUEST_THREADS)
        super().__init__(*args, **kwargs)

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(REQUEST_TIMEOUT_SECONDS)
        try:
            return self._tls_context.wrap_socket(
                connection,
                server_side=True,
            ), address
        except BaseException:
            connection.close()
            raise

    def process_request(self, request, client_address):
        self._request_slots.acquire()
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._request_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._request_slots.release()


TOKEN = Path(os.environ["CREDENTIALS_DIRECTORY"], "token").read_text().strip()
if not TOKEN:
    raise RuntimeError("remote-control token is empty")

PORT = 8901
WLCOPY = "@wlClipboard@/bin/wl-copy"
WLPASTE = "@wlClipboard@/bin/wl-paste"
NIRI = "@niri@/bin/niri"
NOCTALIA = "@noctalia@/bin/noctalia"


def _wayland_env():
    """Build env dict to talk to the user's Wayland/Niri session."""
    pw = pwd.getpwnam("@username@")
    uid = pw.pw_uid
    runtime_dir = f"/run/user/{uid}"

    # Auto-detect WAYLAND_DISPLAY and NIRI_SOCKET from runtime dir
    wayland_display = "wayland-0"
    niri_socket = None
    try:
        for name in sorted(os.listdir(runtime_dir)):
            if name.startswith("wayland-") and not name.endswith(".lock"):
                wayland_display = name
                break
        for name in os.listdir(runtime_dir):
            if name.startswith("niri.") and name.endswith(".sock"):
                niri_socket = os.path.join(runtime_dir, name)
                break
    except OSError:
        pass

    env = {
        "WAYLAND_DISPLAY":        wayland_display,
        "XDG_RUNTIME_DIR":        runtime_dir,
        "DBUS_SESSION_BUS_ADDRESS": f"unix:path=/run/user/{uid}/bus",
        "HOME":                   pw.pw_dir,
    }
    if niri_socket:
        env["NIRI_SOCKET"] = niri_socket
    return env, uid, pw.pw_gid


class Handler(http.server.BaseHTTPRequestHandler):

    # ── helpers ──────────────────────────────────────

    def setup(self):
        super().setup()
        self.connection.settimeout(REQUEST_TIMEOUT_SECONDS)

    def _check_auth(self):
        expected = f"Bearer {TOKEN}"
        if not hmac.compare_digest(self.headers.get("Authorization", ""), expected):
            self._json(401, {"error": "unauthorized"})
            return False
        return True

    def _json(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def _binary(self, code, content_type, data):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def _run(self, cmd, env=None, uid=None, gid=None):
        try:
            r = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                env=env,
                user=uid,
                group=gid,
                timeout=REQUEST_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired:
            return False, "command timed out"
        return r.returncode == 0, r.stderr.strip()

    def _run_action(self, cmd, ok_status, env=None, uid=None, gid=None):
        """Run a command and respond with a standard ok/error JSON."""
        ok, err = self._run(cmd, env=env, uid=uid, gid=gid)
        self._json(200 if ok else 500, {
            "status": ok_status if ok else "error",
            **({"detail": err} if not ok else {}),
        })

    # ── dispatch ─────────────────────────────────────

    def do_POST(self):
        if not self._check_auth():
            return
        path = urlparse(self.path).path
        routes = {
            "/clipboard": self._post_clipboard,
            "/lock": self._post_lock,
            "/unlock": self._post_unlock,
            "/shutdown": self._post_shutdown,
            "/reboot": self._post_reboot,
        }
        handler = routes.get(path)
        if handler:
            handler()
        else:
            self._json(404, {"error": "not found"})

    def do_GET(self):
        if not self._check_auth():
            return
        routes = {
            "/ping":       self._get_ping,
            "/status":     self._get_status,
            "/clipboard":  self._get_clipboard,
            "/screenshot": self._get_screenshot,
        }
        handler = routes.get(urlparse(self.path).path)
        if handler: handler()
        else:       self._json(404, {"error": "not found"})

    # ── GET handlers ─────────────────────────────────

    def _get_ping(self):
        self._json(200, {"status": "ok"})

    def _get_status(self):
        try:
            r = subprocess.run(
                ["loginctl", "list-sessions", "--no-legend"],
                capture_output=True,
                text=True,
                timeout=REQUEST_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired:
            self._json(504, {"error": "loginctl timed out"})
            return
        sessions = []
        for line in r.stdout.strip().splitlines():
            parts = line.split()
            if not parts:
                continue
            sid = parts[0]
            try:
                props = subprocess.run(
                    ["loginctl", "show-session", sid,
                     "-p", "LockedHint", "-p", "Name", "-p", "Type"],
                    capture_output=True,
                    text=True,
                    timeout=REQUEST_TIMEOUT_SECONDS,
                )
            except subprocess.TimeoutExpired:
                self._json(504, {"error": "loginctl timed out"})
                return
            pmap = {}
            for pline in props.stdout.strip().splitlines():
                if "=" in pline:
                    k, v = pline.split("=", 1)
                    pmap[k] = v
            if pmap:
                sessions.append({
                    "id": sid,
                    "locked": pmap.get("LockedHint") == "yes",
                    "user": pmap.get("Name", ""),
                    "type": pmap.get("Type", ""),
                })
        self._json(200, {"sessions": sessions})

    def _get_clipboard(self):
        env, uid, gid = _wayland_env()
        try:
            r = subprocess.run(
                [WLPASTE],
                env=env,
                user=uid,
                group=gid,
                capture_output=True,
                text=True,
                timeout=REQUEST_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired:
            self._json(504, {"error": "clipboard read timed out"})
            return
        if r.returncode == 0:
            self._json(200, {"text": r.stdout})
        else:
            self._json(500, {"status": "error", "detail": r.stderr.strip()})

    def _get_screenshot(self):
        env, uid, gid = _wayland_env()
        with tempfile.TemporaryDirectory(
            prefix="screenshot-",
            dir="@runtimeDirectoryPath@",
        ) as tmp_dir:
            tmp_path = os.path.join(tmp_dir, "screenshot.png")
            try:
                r = subprocess.run(
                    [NIRI, "msg", "action", "screenshot-screen", "--path", tmp_path],
                    env=env,
                    user=uid,
                    group=gid,
                    capture_output=True,
                    text=True,
                    timeout=REQUEST_TIMEOUT_SECONDS,
                )
            except subprocess.TimeoutExpired:
                self._json(504, {"error": "screenshot timed out"})
                return
            if r.returncode != 0:
                self._json(500, {
                    "status": "error",
                    "detail": f"niri screenshot failed: {r.stderr.strip()}",
                })
                return
            try:
                screenshot = Path(tmp_path).read_bytes()
            except OSError as error:
                self._json(500, {
                    "status": "error",
                    "detail": f"could not read screenshot: {error}",
                })
                return
            self._binary(200, "image/png", screenshot)

    # ── POST handlers ────────────────────────────────

    def _post_clipboard(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            self._json(400, {"error": "invalid Content-Length"})
            return
        if length <= 0:
            self._json(400, {"error": "empty body"})
            return
        if length > MAX_BODY_BYTES:
            self._json(413, {"error": "body exceeds 1 MiB"})
            return
        try:
            text = self.rfile.read(length).decode("utf-8") if length else ""
        except UnicodeDecodeError:
            self._json(400, {"error": "body must be UTF-8"})
            return
        if not text:
            self._json(400, {"error": "empty body"})
            return
        env, uid, gid = _wayland_env()
        # wl-copy forks a daemon that never exits — send to DEVNULL
        try:
            r = subprocess.run(
                [WLCOPY, "--", text], env=env, user=uid, group=gid,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, start_new_session=True,
                timeout=REQUEST_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired:
            self._json(504, {"error": "clipboard write timed out"})
            return
        if r.returncode == 0:
            self._json(200, {"status": "copied", "length": len(text)})
        else:
            self._json(500, {"status": "error",
                             "detail": f"wl-copy exited {r.returncode}"})

    def _post_lock(self):
        env, uid, gid = _wayland_env()
        self._run_action(
            [NOCTALIA, "msg", "session", "lock"],
            "locked", env=env, uid=uid, gid=gid)

    def _post_unlock(self):
        env, uid, gid = _wayland_env()
        ok, err = self._run(
            ["loginctl", "unlock-sessions"],
            env=env, uid=uid, gid=gid)
        wake_ok, wake_err = self._run(
            [NIRI, "msg", "action", "power-on-monitors"],
            env=env,
            uid=uid,
            gid=gid,
        )
        success = ok and wake_ok
        self._json(200 if success else 500, {
            "status": "unlocked" if success else "error",
            **({"detail": err or wake_err} if not success else {}),
        })

    def _post_shutdown(self):
        self._run_action(["systemctl", "poweroff"], "shutting down")

    def _post_reboot(self):
        self._run_action(["systemctl", "reboot"], "rebooting")

    def log_message(self, fmt, *args):
        print(f"{args[0]} {args[1]} {args[2]}")


if __name__ == "__main__":
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.minimum_version = ssl.TLSVersion.TLSv1_2
    tls.load_cert_chain("@certificatePath@", "@privateKeyPath@")

    srv = BoundedThreadingHTTPServer(
        ("@lanAddress@", PORT),
        Handler,
        tls_context=tls,
    )
    print(f"remote-control listening on https://@lanAddress@:{PORT}")
    srv.serve_forever()
