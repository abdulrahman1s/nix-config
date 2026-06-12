{
  description = "NixOS configuration flake";

  nixConfig = {
    extra-substituters = [
      "https://nixos-cache-proxy.cofob.dev"
      "https://cache.nixos-cuda.org"
      "https://attic.xuyh0120.win/lantian" # primary cache for nix-cachyos-kernel
      "https://cache.garnix.io" # fallback cache for nix-cachyos-kernel
      "https://noctalia.cachix.org" # pre-built noctalia-shell / quickshell
    ];
    extra-trusted-public-keys = [
      "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
      "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc="
      "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
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

    brave-previews = {
      url = "github:kcalvelli/brave-browser-previews";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    noctalia = {
      url = "github:noctalia-dev/noctalia-shell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-dokploy.url = "github:el-kurto/nix-dokploy";
    nix-dokploy.inputs.nixpkgs.follows = "nixpkgs";

    qsh.url = "github:abdulrahman1s/qsh";
    qsh.inputs.nixpkgs.follows = "nixpkgs";

    github-fs.url = "github:abdulrahman1s/github-fs";
    github-fs.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, agenix, nixpak, nixos-hardware, nix-cachyos-kernel, noctalia, brave-previews, nix-dokploy, github-fs, qsh, ... } @ inputs:
    let
      system = "x86_64-linux";
      userArgs = import ./specialArgs.nix;
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      nixosConfigurations.default = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; } // userArgs;
        modules = [
          agenix.nixosModules.default
          brave-previews.nixosModules.default
          nix-dokploy.nixosModules.default
          qsh.nixosModules.default
          github-fs.nixosModules.default
          { nixpkgs.overlays = [ nix-cachyos-kernel.overlays.pinned ]; }
          nixos-hardware.nixosModules.asus-rog-strix-x570e
          nixos-hardware.nixosModules.common-gpu-nvidia-nonprime
          nixos-hardware.nixosModules.common-pc
          ./configuration.nix
        ];
      };

      checks.${system}.pathbinding =
        import ./sandboxed-apps/test-pathbinding.nix { inherit pkgs nixpak; };
    };
}
