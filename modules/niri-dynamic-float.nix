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
  #   center  — optional; recenter the floating window whenever its size changes
  rules = [
    { app_id = "^brave-origin$"; title = "^DevTools - "; width = 900; height = 1000; }
    { app_id = "^brave-"; title = "^Bitwarden$"; width = 610; height = 787; }
    { app_id = "^\\.?digup-shell(-wrapped_*)?$"; title = "^DigUp$"; center = true; }
  ];

  rulesJson = builtins.toJSON rules;

  script = pkgs.writeTextFile {
    name = "niri-dynamic-float";
    executable = true;
    text = builtins.replaceStrings
      [ "@python3@" "@rulesJson@" ]
      [ "${pkgs.python3}" rulesJson ]
      (builtins.readFile ./niri-dynamic-float.py);
  };
in
{
  systemd.user.services.niri-dynamic-float = {
    description = "Float matching niri windows and keep resizing search panels centered";
    after = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];

    serviceConfig = {
      ExecStart = "${script}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
