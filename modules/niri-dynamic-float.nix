{ pkgs, ... }:
let
  # ── Dynamic float rules ──────────────────────────────────
  # Each rule is checked against every window title/app_id change.
  # All specified fields must match for the window to be floated.
  #   app_id  — regex matched against the window's app_id
  #   title   — regex matched against the window's title
  #   exclude — optional regex; if it matches the title, the rule is skipped
  #   width   — optional; set the floating window width in logical pixels
  #   height  — optional; set the floating window height in logical pixels
  rules = [
    { app_id = "^brave-origin-nightly$"; title = "^DevTools - "; width = 900; height = 1000; }
    { app_id = "^brave-"; title = "^Bitwarden$"; width = 610; height = 787; }
  ];

  rulesJson = builtins.toJSON rules;

  script = pkgs.writeTextFile {
    name = "niri-dynamic-float";
    executable = true;
    text = ''
      #!${pkgs.python3}/bin/python3
      """
      niri-dynamic-float — float windows whose title/app_id matches rules
      after the window has already been mapped (works around niri's
      open-time-only evaluation of open-floating).
      """

      import json
      import os
      import re
      import socket
      import stat
      import sys
      import time
      from pathlib import Path

      RULES = json.loads(r"""${rulesJson}""")


      def niri_socket_path():
          path = os.environ.get("NIRI_SOCKET")
          if path:
              try:
                  if stat.S_ISSOCK(os.stat(path).st_mode):
                      return path
              except FileNotFoundError:
                  pass

          runtime_dir = Path(
              os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
          )
          sockets = []
          for candidate in runtime_dir.glob("niri.*.sock"):
              try:
                  if stat.S_ISSOCK(candidate.stat().st_mode):
                      sockets.append(candidate)
              except FileNotFoundError:
                  continue

          if not sockets:
              raise RuntimeError(f"No niri socket found in {runtime_dir}")

          path = str(max(sockets, key=lambda candidate: candidate.stat().st_mtime_ns))
          os.environ["NIRI_SOCKET"] = path
          return path


      def niri_action(action):
          """Open a throwaway connection, send an action, return the response."""
          path = niri_socket_path()
          with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
              s.connect(path)
              s.sendall(json.dumps({"Action": action}).encode() + b"\n")
              buf = b""
              while b"\n" not in buf:
                  chunk = s.recv(4096)
                  if not chunk:
                      break
                  buf += chunk
          return json.loads(buf.decode()) if buf.strip() else {}


      def matching_rule(window):
          """Return the first matching rule, or None."""
          app_id = window.get("app_id") or ""
          title = window.get("title") or ""
          for rule in RULES:
              if "app_id" in rule and not re.search(rule["app_id"], app_id):
                  continue
              if "title" in rule and not re.search(rule["title"], title):
                  continue
              if "exclude" in rule and re.search(rule["exclude"], title):
                  continue
              return rule
          return None


      def try_float(window, floated):
          wid = window["id"]
          if wid in floated:
              return
          rule = matching_rule(window)
          if rule is None:
              return
          floated.add(wid)
          niri_action({"MoveWindowToFloating": {"id": wid}})
          title = window.get("title", "")
          print(f"Floated {wid} ({title!r})", flush=True)

          # Resize if the rule specifies dimensions — focus first since
          # SetColumnWidth / SetWindowHeight operate on the focused window.
          width = rule.get("width")
          height = rule.get("height")
          if width or height:
              restore_focus = not window.get("is_focused", False)
              if restore_focus:
                  niri_action({"FocusWindow": {"id": wid}})
              try:
                  if width:
                      niri_action({"SetColumnWidth": {"change": {"SetFixed": width}}})
                  if height:
                      niri_action({"SetWindowHeight": {"change": {"SetFixed": height}}})
              finally:
                  if restore_focus:
                      niri_action({"FocusWindowPrevious": {}})


      def event_loop():
          path = niri_socket_path()
          with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
              s.connect(path)
              s.sendall(json.dumps("EventStream").encode() + b"\n")

              floated: set[int] = set()
              titles: dict[int, str] = {}
              buf = b""

              while True:
                  chunk = s.recv(8192)
                  if not chunk:
                      raise ConnectionError("niri socket closed")

                  buf += chunk
                  while b"\n" in buf:
                      line, buf = buf.split(b"\n", 1)
                      if not line.strip():
                          continue

                      event = json.loads(line.decode())

                      if "WindowsChanged" in event:
                          for w in event["WindowsChanged"]["windows"]:
                              titles[w["id"]] = w.get("title", "")
                              try_float(w, floated)

                      elif "WindowOpenedOrChanged" in event:
                          w = event["WindowOpenedOrChanged"]["window"]
                          wid = w["id"]
                          old_title = titles.get(wid)
                          new_title = w.get("title", "")
                          if old_title is not None and old_title != new_title:
                              print(f"Title changed {wid}: {old_title!r} -> {new_title!r}", flush=True)
                          titles[wid] = new_title
                          try_float(w, floated)

                      elif "WindowClosed" in event:
                          wid = event["WindowClosed"]["id"]
                          floated.discard(wid)
                          titles.pop(wid, None)


      def main():
          print(
              f"niri-dynamic-float: starting with {len(RULES)} rule(s)",
              flush=True,
          )
          for r in RULES:
              print(f"  {r}", flush=True)

          while True:
              try:
                  event_loop()
              except Exception as e:
                  print(f"Error: {e} — restarting in 5 s", file=sys.stderr, flush=True)
                  os.environ.pop("NIRI_SOCKET", None)
                  time.sleep(5)


      if __name__ == "__main__":
          main()
    '';
  };
in
{
  systemd.user.services.niri-dynamic-float = {
    description = "Float niri windows whose title changes to match rules after open";
    after = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];

    serviceConfig = {
      ExecStart = "${script}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
