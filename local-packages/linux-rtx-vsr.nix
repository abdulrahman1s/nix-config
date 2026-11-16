{ pkgs }:
let
  inherit (pkgs) lib;
  source = pkgs.fetchFromGitHub {
    owner = "abdulrahman1s";
    repo = "linux-rtx-vsr";
    rev = "86aae5c0b9d59041c15e01688632926dd7f4e005";
    hash = "sha256-qKYdfgkr8DaTiXqSonc5KOu4dq/cjhO5WgmhOzz0pYk=";
  };
  application = pkgs.rustPlatform.buildRustPackage {
    pname = "linux-rtx-vsr";
    version = "0.5.0-unstable-2026-11-10";
    src = source;
    cargoLock.lockFile = "${source}/Cargo.lock";
    nativeBuildInputs = [ pkgs.bun ];
    postCheck = ''
      bun test tests/policy.test.ts tests/timing.test.ts tests/worker.test.ts tests/decoder.test.ts tests/color.test.ts tests/resolution.test.ts tests/startup.test.ts tests/pacer.test.ts
    '';
    postInstall = ''
      mkdir -p "$out/share/linux-rtx-vsr"
      bun scripts/build-extension.ts
      cp -r docs licenses scripts README.md LICENSE THIRD_PARTY.md "$out/share/linux-rtx-vsr/"
      cp -r build/extension "$out/share/linux-rtx-vsr/"
      bun scripts/collect-licenses.ts --offline --output "$out/share/linux-rtx-vsr/licenses/rust-dependencies.txt"
    '';
    meta = {
      description = "Local NVIDIA VideoSuperRes for Brave with playback status badges";
      homepage = "https://github.com/abdulrahman1s/linux-rtx-vsr";
      license = lib.licenses.mit;
      mainProgram = "linux-rtx-vsr";
      platforms = [ "x86_64-linux" ];
    };
  };
in
pkgs.callPackage "${source}/nix/runtime-wrapper.nix" {
  package = application;
  runtime = pkgs.callPackage ./nvidia-vfx.nix { };
}
