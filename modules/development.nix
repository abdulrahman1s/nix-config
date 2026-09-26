{ pkgs, username, fullName, email, ... }: {

  virtualisation.podman = {
    enable = true;
    # dockerCompat = true;
    # dockerSocket.enable = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  programs.git = {
    enable = true;
    config = {
      user.name = fullName;
      user.email = email;
    };
  };

  programs.direnv = {
    enable = true;
    silent = true;
    loadInNixShell = true;
    direnvrcExtra = "";
    nix-direnv = {
      enable = true;
      package = pkgs.nix-direnv;
    };
  };

  environment.systemPackages = with pkgs; [
    devenv
  ];

  # Nested rootless containers (rootless podman running e.g.
  # `moby/buildkit:rootless`) need enough sub-UIDs to allocate a second
  # user namespace inside the outer one. The default 65536 only covers
  # the outer container's mapping; the inner rootlesskit then fails with
  # `newuidmap: write to uid_map failed: Operation not permitted`.
  # 1M leaves comfortable headroom for `podman --userns=auto:size=…`.
  users.users.${username} = {
    subUidRanges = [{ startUid = 100000; count = 1000000; }];
    subGidRanges = [{ startGid = 100000; count = 1000000; }];
    packages = with pkgs; [
      # Editors
      zed-editor

      # Container tools
      lazydocker

      # Build tools
      gnumake
      git-lfs
      pkg-config
      stdenv.cc
      mold

      # Web development
      nodejs_24
      bun

      # Android development
      android-tools

      # Python development
      (python3.withPackages (pythonPackages: [ pythonPackages.pip ]))

      # Nix tooling
      nixpkgs-fmt
      nixd # Nix LSP with NixOS option completion
      nix-prefetch-github
      nvd

      # Other development tools
      onefetch
    ];
  };


}
