{
  description = "NixOS configuration flake";

  nixConfig = {
    extra-substituters = [
      "https://nixos-cache-proxy.cofob.dev"
      "https://cache.nixos.org" # fallback when the Cloudflare proxy is unavailable
      "https://cache.nixos-cuda.org"
      "https://attic.xuyh0120.win/lantian" # primary cache for nix-cachyos-kernel
      "https://noctalia.cachix.org" # pre-built Noctalia v5
    ];
    extra-trusted-public-keys = [
      "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
      "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc="
      "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
    ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixpak = {
      url = "github:nixpak/nixpak";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";

    noctalia.url = "github:noctalia-dev/noctalia";

    qsh.url = "github:abdulrahman1s/qsh";
    qsh.inputs.nixpkgs.follows = "nixpkgs";

    steam-cleaner.url = "github:abdulrahman1s/steam-cleaner";
    steam-cleaner.inputs.nixpkgs.follows = "nixpkgs";

    github-fs.url = "github:abdulrahman1s/github-fs";
    github-fs.inputs.nixpkgs.follows = "nixpkgs";

    impermanence.url = "github:nix-community/impermanence";
    impermanence.inputs.nixpkgs.follows = "nixpkgs";

    hjem = {
      url = "github:feel-co/hjem/b610953d0c56da6b28fd39c21bd193b88e91341c";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs = { self, nixpkgs, agenix, nixpak, nixos-hardware, nix-cachyos-kernel, noctalia, github-fs, qsh, steam-cleaner, impermanence, hjem, disko, ... } @ inputs:
    let
      system = "x86_64-linux";
      userArgs = import ./specialArgs.nix;
      pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
      maintainedPackages = import ./nix-packages { inherit pkgs inputs; };
      recoverySystem = self.nixosConfigurations.recovery.config.system.build.toplevel;
      recoveryDiskoScript = self.nixosConfigurations.recovery.config.system.build.diskoScript;
      recoveryDiskoUnmountScript = self.nixosConfigurations.recovery.config.system.build.unmount;
      recoveryPartition = pkgs.writeShellApplication {
        name = "recovery-partition";
        runtimeInputs = with pkgs; [
          coreutils
          gnugrep
          systemd
          util-linux
        ];
        text = ''
          export RECOVERY_DISKO_SCRIPT=${recoveryDiskoScript}
          export RECOVERY_DISKO_UNMOUNT_SCRIPT=${recoveryDiskoUnmountScript}
          ${builtins.readFile ./recovery/recovery-partition.sh}
        '';
      };
      recoveryUpdate = pkgs.writeShellApplication {
        name = "recovery-update";
        runtimeInputs = with pkgs; [
          coreutils
          nixos-install-tools
          util-linux
        ];
        text = ''
          export RECOVERY_SYSTEM=${recoverySystem}
          ${builtins.readFile ./recovery/recovery-update.sh}
        '';
      };
    in
    {
      nixosConfigurations.default = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; } // userArgs;
        modules = [
          agenix.nixosModules.default
          qsh.nixosModules.default
          steam-cleaner.nixosModules.default
          github-fs.nixosModules.default
          impermanence.nixosModules.impermanence
          hjem.nixosModules.default
          { nixpkgs.overlays = [ nix-cachyos-kernel.overlays.pinned ]; }
          nixos-hardware.nixosModules.asus-rog-strix-x570e
          nixos-hardware.nixosModules.common-gpu-nvidia-nonprime
          nixos-hardware.nixosModules.common-pc
          ./configuration.nix
        ];
      };

      nixosConfigurations.recovery = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; } // userArgs;
        modules = [
          disko.nixosModules.disko
          ./recovery/disko.nix
          ./recovery/configuration.nix
        ];
      };

      packages.${system} = {
        inherit (maintainedPackages) codex chatgpt photocraft filmcraft sklauncher claude-code brave-origin noctalia niri;
        recovery-partition = recoveryPartition;
        recovery-update = recoveryUpdate;
      };

      apps.${system} = {
        recovery-partition = {
          type = "app";
          program = "${recoveryPartition}/bin/recovery-partition";
        };
        recovery-update = {
          type = "app";
          program = "${recoveryUpdate}/bin/recovery-update";
        };
      };

      formatter.${system} = pkgs.nixpkgs-fmt;

      checks.${system} = {
        nixos = self.nixosConfigurations.default.config.system.build.toplevel;
        recovery = recoverySystem;
        pathbinding =
          import ./sandboxed-apps/test-pathbinding.nix { inherit pkgs nixpak; };
        sandbox-gpu-devices =
          import ./sandboxed-apps/test-gpu-devices.nix { inherit pkgs nixpak; };
        sandbox-system-trust =
          import ./sandboxed-apps/test-system-trust.nix { inherit pkgs nixpak; };
      };
    };
}
