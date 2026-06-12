{ pkgs, inputs, username, lanAddress, ... }:

let
  port = 8901;
  tokenPath = "/etc/remote-control.token";
  noctalia-shell = inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default;
  server = pkgs.writeText "remote-control-server.py" ''
    #!/usr/bin/env python3
    """Remote control HTTP server for NixOS + Niri.

    Endpoints:
      GET  /ping        — health check
      GET  /unlock      — unlock all sessions and wake monitors
      GET  /lock        — lock all sessions
      GET  /status      — show session lock state
      GET  /clipboard   — read clipboard
      POST /clipboard   — set clipboard (send text as raw body)
      GET  /screenshot  — capture focused screen via niri and return PNG
      GET  /shutdown    — power off
      GET  /reboot      — reboot

    Auth: Bearer token via Authorization header.
    Token is read from ${tokenPath} (auto-generated on first boot).
    """

    import http.server
    import socketserver
    import subprocess
    import json
    import hmac
    import pwd
    import os
    from pathlib import Path
    from urllib.parse import urlparse

    class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True

    TOKEN   = Path("${tokenPath}").read_text().strip()
    PORT    = ${toString port}
    WLCOPY  = "${pkgs.wl-clipboard}/bin/wl-copy"
    WLPASTE = "${pkgs.wl-clipboard}/bin/wl-paste"
    NIRI    = "${pkgs.niri}/bin/niri"
    NOCTALIA = "${noctalia-shell}/bin/noctalia-shell"

    def _wayland_env():
        """Build env dict to talk to the user's Wayland/Niri session."""
        pw  = pwd.getpwnam("${username}")
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

        def _check_auth(self):
            if not hmac.compare_digest(self.headers.get("Authorization", ""), TOKEN):
                self._json(401, {"error": "unauthorized"})
                return False
            return True

        def _json(self, code, data):
            body = json.dumps(data).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _binary(self, code, content_type, data):
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _run(self, cmd, env=None, uid=None, gid=None):
            r = subprocess.run(cmd, capture_output=True, text=True,
                               env=env, user=uid, group=gid)
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
            if   path == "/clipboard": self._post_clipboard()
            else:                      self._json(404, {"error": "not found"})

        def do_GET(self):
            if not self._check_auth():
                return
            routes = {
                "/ping":       self._get_ping,
                "/status":     self._get_status,
                "/clipboard":  self._get_clipboard,
                "/lock":       self._get_lock,
                "/unlock":     self._get_unlock,
                "/shutdown":   self._get_shutdown,
                "/reboot":     self._get_reboot,
                "/screenshot": self._get_screenshot,
            }
            handler = routes.get(urlparse(self.path).path)
            if handler: handler()
            else:       self._json(404, {"error": "not found"})

        # ── GET handlers ─────────────────────────────────

        def _get_ping(self):
            self._json(200, {"status": "ok"})

        def _get_status(self):
            r = subprocess.run(["loginctl", "list-sessions", "--no-legend"],
                               capture_output=True, text=True)
            sessions = []
            for line in r.stdout.strip().splitlines():
                parts = line.split()
                if not parts:
                    continue
                sid = parts[0]
                props = subprocess.run(
                    ["loginctl", "show-session", sid,
                     "-p", "LockedHint", "-p", "Name", "-p", "Type"],
                    capture_output=True, text=True,
                )
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
            r = subprocess.run([WLPASTE], env=env, user=uid, group=gid,
                               capture_output=True, text=True)
            if r.returncode == 0:
                self._json(200, {"text": r.stdout})
            else:
                self._json(500, {"status": "error", "detail": r.stderr.strip()})

        def _get_lock(self):
            env, uid, gid = _wayland_env()
            self._run_action(
                [NOCTALIA, "ipc", "call", "lockScreen", "lock"],
                "locked", env=env, uid=uid, gid=gid)

        def _get_unlock(self):
            env, uid, gid = _wayland_env()
            ok, err = self._run(
                [NOCTALIA, "ipc", "call", "lockScreen", "unlock"],
                env=env, uid=uid, gid=gid)
            # Wake monitors from DPMS sleep via niri
            subprocess.run(
                [NIRI, "msg", "action", "power-on-monitors"],
                env=env, user=uid, group=gid,
                capture_output=True, text=True,
            )
            self._json(200 if ok else 500, {
                "status": "unlocked" if ok else "error",
                **({"detail": err} if not ok else {}),
            })

        def _get_shutdown(self):
            self._run_action(["systemctl", "poweroff"], "shutting down")

        def _get_reboot(self):
            self._run_action(["systemctl", "reboot"], "rebooting")

        def _get_screenshot(self):
            env, uid, gid = _wayland_env()
            tmp_path = f"/tmp/remote-control-screenshot-{os.getpid()}.png"
            r = subprocess.run(
                [NIRI, "msg", "action", "screenshot-screen", "--path", tmp_path],
                env=env, user=uid, group=gid,
                capture_output=True, text=True,
            )
            if r.returncode != 0:
                self._json(500, {"status": "error",
                                 "detail": f"niri screenshot failed: {r.stderr.strip()}"})
                return

            try:
                self._binary(200, "image/png", Path(tmp_path).read_bytes())
            finally:
                try:    os.unlink(tmp_path)
                except OSError: pass

        # ── POST handlers ────────────────────────────────

        def _post_clipboard(self):
            length = int(self.headers.get("Content-Length", 0))
            text = self.rfile.read(length).decode("utf-8") if length else ""
            if not text:
                self._json(400, {"error": "empty body"})
                return
            env, uid, gid = _wayland_env()
            # wl-copy forks a daemon that never exits — send to DEVNULL
            r = subprocess.run(
                [WLCOPY, "--", text], env=env, user=uid, group=gid,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, start_new_session=True,
            )
            if r.returncode == 0:
                self._json(200, {"status": "copied", "length": len(text)})
            else:
                self._json(500, {"status": "error",
                                 "detail": f"wl-copy exited {r.returncode}"})

        def log_message(self, fmt, *args):
            print(f"{args[0]} {args[1]} {args[2]}")

    if __name__ == "__main__":
        srv = ThreadingHTTPServer(("${lanAddress}", PORT), Handler)
        print(f"remote-control listening on ${lanAddress}:{PORT}")
        srv.serve_forever()
  '';
in
{


  # Auto-generate a bearer token on first boot
  system.activationScripts.remote-control-token = ''
    if [ ! -f ${tokenPath} ]; then
      ${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/base64 | ${pkgs.coreutils}/bin/tr -d '/+\n' > ${tokenPath}
      chmod 600 ${tokenPath}
      echo "remote-control: generated new token at ${tokenPath}"
    fi
  '';

  # ── HTTP server service ─────────────────────────────────
  systemd.services.remote-control = {
    description = "Remote session control HTTP server";
    after       = [ "network.target" ];
    wantedBy    = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart  = "${pkgs.python3}/bin/python3 ${server}";
      Restart    = "always";
      RestartSec = "3";
    };
  };
}
