# Regression test for GPU device coverage in the shared sandbox preset.
{ pkgs, nixpak }:

let
  helpers = import ./nixpak { inherit pkgs nixpak; };

  stubPackage = pkgs.writeShellApplication {
    name = "test-gpu-devices";
    text = ''
      for key in VK_DRIVER_FILES __EGL_VENDOR_LIBRARY_FILENAMES GBM_BACKEND; do
        if [[ -v $key ]]; then
          echo "Unexpected empty GPU override: $key" >&2
          exit 1
        fi
      done
      if [[ $VK_ICD_FILENAMES != /test/driver.json ]]; then
        echo "Nonempty GPU driver override was lost" >&2
        exit 1
      fi
    '';
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
    config_file=$(${pkgs.gnused}/bin/sed -n '2p' "$launcher")
    args_file=$(jq -r '.bwrap.args' "$config_file")
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

    # Run the application's inner wrapper with Sloth's empty fallbacks, without
    # requiring a GPU or nested user namespaces in the Nix build sandbox.
    app=$(${pkgs.gnused}/bin/sed -n '3p' "$launcher")
    env VK_DRIVER_FILES= __EGL_VENDOR_LIBRARY_FILENAMES= GBM_BACKEND= \
      VK_ICD_FILENAMES=/test/driver.json "$app"

    touch "$out"
  ''
