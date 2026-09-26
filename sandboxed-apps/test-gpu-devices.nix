# Regression test for GPU device coverage in the shared sandbox preset.
{ pkgs, nixpak }:

let
  helpers = import ./nixpak { inherit pkgs nixpak; };

  stubPackage = pkgs.writeShellApplication {
    name = "test-gpu-devices";
    text = "exit 0";
  };

  sandbox = helpers.mkSandboxed {
    package = stubPackage;
    name = "test-gpu-devices";
    exportDesktopFiles = false;
    presets = [ "gpu" ];
  };
in
pkgs.runCommand "sandbox-gpu-devices-test"
{
  nativeBuildInputs = [
    pkgs.coreutils
    pkgs.jq
  ];
}
  ''
    set -euo pipefail

    launcher=$(${pkgs.coreutils}/bin/readlink -f ${sandbox}/bin/test-gpu-devices)
    args_file=$(${pkgs.gnused}/bin/sed -n \
      "s|^export BUBBLEWRAP_ARGS='\\(.*\\)'$|\\1|p" "$launcher")
    test -n "$args_file"

    for device in \
      /dev/dri \
      /dev/nvidia0 \
      /dev/nvidiactl \
      /dev/nvidia-modeset \
      /dev/nvidia-uvm \
      /dev/nvidia-uvm-tools \
      /dev/nvidia-caps
    do
      # A complete --dev-bind-try has one source and one destination entry.
      test "$(jq --arg device "$device" \
        '[.[] | select(. == $device)] | length' "$args_file")" -eq 2
    done

    touch "$out"
  ''
