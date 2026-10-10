{ pkgs, inputs }:
let
  system = pkgs.stdenv.hostPlatform.system;
  versions = builtins.fromJSON (builtins.readFile ./versions.json);
in
{
  codex = pkgs.callPackage ./codex.nix {
    inherit (versions) codex;
  };

  chatgpt = pkgs.callPackage ./chatgpt.nix {
    inherit (versions) chatgpt;
  };

  photocraft = pkgs.callPackage ./photocraft.nix {
    inherit (versions) photocraft;
  };

  filmcraft = pkgs.callPackage ./filmcraft.nix {
    inherit (versions) filmcraft;
  };

  sklauncher = pkgs.callPackage ./sklauncher.nix {
    inherit (versions) sklauncher;
  };

  claude-code = pkgs.claude-code.override {
    manifest = {
      version = versions.claude.version;
      platforms.linux-x64.checksum = versions.claude.sha256;
    };
  };

  brave-origin = pkgs.brave-origin.overrideAttrs (_: {
    version = versions.brave-origin.version;
    src = pkgs.fetchurl {
      url = "https://github.com/brave/brave-browser/releases/download/v${versions.brave-origin.version}/brave-origin_${versions.brave-origin.version}_amd64.deb";
      hash = versions.brave-origin.hash;
    };
  });

  noctalia = inputs.noctalia.packages.${system}.default.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./noctalia-bar-hide-delay.patch ];
  });
  niri = pkgs.niri;
}
