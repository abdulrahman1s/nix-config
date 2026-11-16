{
  description = "NixOS configuration flake";

  nixConfig = {
    extra-substituters = [
      "https://nixos-cache-proxy.cofob.dev"
      "https://cache.nixos.org" # fallback when the Cloudflare proxy is unavailable
      "https://cache.nixos-cuda.org"
      "https://noctalia.cachix.org" # pre-built Noctalia v5
      "https://abdulrahman1s-nix-cache.citizen6775.workers.dev" # Authenticated R2 cache
    ];
    # Cache keys are trusted by the daemon in configuration.nix. Submitting
    # them here warns on every build by an untrusted user, even for known keys.
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

    # Local checkout; `ref` pins the committed branch so uncommitted work never leaks in.
    # Pick up new commits with `nix flake update easyplay`.
    easyplay.url = "git+file:///home/abdulrahman/projects/easyplay?ref=master";
    easyplay.inputs.nixpkgs.follows = "nixpkgs";

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

  outputs = { self, nixpkgs, agenix, nixpak, nixos-hardware, nix-cachyos-kernel, noctalia, github-fs, qsh, steam-cleaner, easyplay, impermanence, hjem, disko, ... } @ inputs:
    let
      system = "x86_64-linux";
      userArgs = import ./specialArgs.nix;
      # Reuse the system's nixpkgs instance. System modules consume these packages
      # through inputs.self, and a separate import costs about a second per rebuild.
      pkgs = self.nixosConfigurations.default.pkgs;
      maintainedPackages = import ./nix-packages { inherit pkgs inputs; };
      recoverySystem = self.nixosConfigurations.recovery.config.system.build.toplevel;
      recoveryDiskoScript = self.nixosConfigurations.recovery.config.system.build.diskoScript;
      recoveryDiskoUnmountScript = self.nixosConfigurations.recovery.config.system.build.unmount;
      recoveryUsbConfig = self.nixosConfigurations.recovery-usb.config;
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
          ${builtins.readFile ./recovery/apps/recovery-partition.sh}
        '';
      };
      recoveryUpdate = pkgs.writeShellApplication {
        name = "recovery-update";
        runtimeInputs = with pkgs; [
          coreutils
          jq
          nixos-install-tools
          util-linux
        ];
        text = ''
          export RECOVERY_SYSTEM=${recoverySystem}
          export RECOVERY_USERNAME=${nixpkgs.lib.escapeShellArg userArgs.username}
          ${builtins.readFile ./recovery/apps/copy-logins.sh}
          ${builtins.readFile ./recovery/apps/recovery-update.sh}
        '';
      };
      # Installs the recovery system on a USB drive; see recovery/usb.nix.
      recoveryUsb = pkgs.writeShellApplication {
        name = "recovery-usb";
        runtimeInputs = with pkgs; [
          coreutils
          dosfstools
          e2fsprogs
          gawk
          gnugrep
          gptfdisk
          jq
          nixos-install-tools
          systemd
          util-linux
        ];
        text = ''
          export RECOVERY_SYSTEM=${recoveryUsbConfig.system.build.toplevel}
          export RECOVERY_USERNAME=${nixpkgs.lib.escapeShellArg userArgs.username}
          export RECOVERY_USB_ROOT_LABEL=${recoveryUsbConfig.fileSystems."/".label}
          export RECOVERY_USB_EFI_LABEL=${recoveryUsbConfig.fileSystems."/boot".label}
          # Every filesystem the main system mounts; recovery-usb refuses a
          # drive that holds one of them.
          export RECOVERY_USB_PROTECTED=${pkgs.writeText "main-filesystems.json" (builtins.toJSON (
            nixpkgs.lib.mapAttrsToList (mountPoint: fs: { inherit mountPoint; inherit (fs) device; })
              self.nixosConfigurations.default.config.fileSystems
          ))}
          ${builtins.readFile ./recovery/apps/copy-logins.sh}
          ${builtins.readFile ./recovery/apps/recovery-usb.sh}
        '';
      };
      # Boots the recovery configuration in QEMU, signed in to Claude Code and
      # Codex; see recovery/vm.nix.
      recoveryVm = pkgs.writeShellApplication {
        name = "recovery-vm";
        runtimeInputs = with pkgs; [
          coreutils
          jq
        ];
        text = ''
          export RECOVERY_VM=${self.nixosConfigurations.recovery.config.system.build.vm}/bin/run-nixos-recovery-vm
          ${builtins.readFile ./recovery/apps/recovery-vm.sh}
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
          easyplay.nixosModules.default
          github-fs.nixosModules.default
          impermanence.nixosModules.impermanence
          hjem.nixosModules.default
          {
            nixpkgs.overlays = [
              nix-cachyos-kernel.overlays.pinned
              (_final: prev: {
                # One upstream test fixture uses Bash conditionals under /bin/sh.
                protontricks = prev.protontricks.overrideAttrs (old: {
                  disabledTestPaths = (old.disabledTestPaths or [ ]) ++ [
                    "tests/test_flatpak.py::TestGetInaccessiblePaths::test_flatpak_xdg_user_dir"
                  ];
                });
              })
            ];
          }
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

      # The same recovery system for a USB drive, without the SN350 layout.
      nixosConfigurations.recovery-usb = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; } // userArgs;
        modules = [
          ./recovery/configuration.nix
          ./recovery/usb.nix
        ];
      };

      packages.${system} = {
        inherit (maintainedPackages) codex chatgpt photocraft filmcraft sklauncher mangodisk claude-code brave-origin noctalia niri;
        recovery-partition = recoveryPartition;
        recovery-update = recoveryUpdate;
        recovery-usb = recoveryUsb;
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
        recovery-usb = {
          type = "app";
          program = "${recoveryUsb}/bin/recovery-usb";
        };
        recovery-vm = {
          type = "app";
          program = "${recoveryVm}/bin/recovery-vm";
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
        sandbox-runtime-isolation =
          import ./sandboxed-apps/test-runtime-isolation.nix { inherit pkgs nixpak; };
      };
    };
}
