{ pkgs, username, fullName, lib, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      ./packages.nix
      ./services

      # Feature modules
      ./modules/gaming.nix
      ./modules/development.nix
      ./modules/ios.nix
      ./modules/ai.nix
      ./modules/remote-control.nix
      ./modules/niri-dynamic-float.nix
      ./modules/vicinae.nix

      # System
      ./system/audio.nix
      ./system/bluetooth.nix
      ./system/graphics.nix
      ./system/networking.nix
      ./system/security.nix
      ./system/optimization.nix
      ./system/impermanence.nix
      ./system/users.nix

      # Terminal & shell
      ./terminal/shell.nix
      ./terminal/packages.nix
      ./terminal/dotfiles.nix
      ./terminal/ghostty.nix

      # Sandboxed applications
      ./sandboxed-apps
    ];

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    accept-flake-config = true;
    trusted-users = [ "root" username ];
    substituters = lib.mkForce [
      "https://nixos-cache-proxy.cofob.dev"
      "https://cache.nixos.org" # fallback when the Cloudflare proxy is unavailable
      "https://cache.nixos-cuda.org"
      "https://attic.xuyh0120.win/lantian"
      "https://cache.garnix.io"
      "https://noctalia.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
      "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc="
      "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
      "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
    ];
    http-connections = 50;
    warn-dirty = false;
    # During builds, collect only unreachable store paths before free space
    # becomes critical. System generations remain GC roots and stay roll-backable.
    min-free = 25 * 1024 * 1024 * 1024;
    max-free = 35 * 1024 * 1024 * 1024;
  };

  # Keep enough rollback entries without letting copied kernels/initrds fill EFI.
  boot.loader.limine.maxGenerations = 10;

  time.timeZone = "Africa/Cairo";
  i18n.defaultLocale = "en_US.UTF-8";

  fonts.packages = with pkgs; [
    nerd-fonts.fira-code
    nerd-fonts.jetbrains-mono
    dejavu_fonts
    noto-fonts
  ];

  users.users.${username} = {
    isNormalUser = true;
    description = fullName;
    extraGroups = [
      "networkmanager"
      "wheel"
      "libvirtd"
      "podman"
      "docker"
      "openrazer"
    ];
  };

    services.tailscale.enable = true;


  # Fixes Gnome Display Manager fails to login until Wi-Fi connection is established.
  # SEE: https://discourse.nixos.org/t/gnome-display-manager-fails-to-login-until-wi-fi-connection-is-established/50513/14
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;




  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "23.11"; # Did you read the comment?
}
