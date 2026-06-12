{ pkgs, ... }:

let
  # Portal-aware xdg-open using dbus-send to communicate with xdg-desktop-portal
  # https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.OpenURI.html
  mkSandboxedXdgUtils = pkgs.writeShellScriptBin "xdg-open" ''
    if [ -z "$1" ]; then
      echo "Usage: xdg-open <url>" >&2
      exit 1
    fi

    exec ${pkgs.dbus}/bin/dbus-send \
      --session \
      --print-reply \
      --dest=org.freedesktop.portal.Desktop \
      /org/freedesktop/portal/desktop \
      org.freedesktop.portal.OpenURI.OpenURI \
      string:"" \
      string:"$1" \
      array:dict:string:variant:
  '';
in
pkgs.symlinkJoin {
  name = "sandboxed-xdg-utils";
  paths = [
    mkSandboxedXdgUtils
    pkgs.xdg-utils
  ];
}
