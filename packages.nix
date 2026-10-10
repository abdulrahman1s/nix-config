{ inputs, pkgs, username, ... }:

let
  browserUse = pkgs.callPackage ./local-packages/browser-use.nix { };
in

{


  # ── Nix LD (dynamic library fix for unpackaged binaries) ───
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    libGL
    libz
  ];

  programs.steam-cleaner.enable = true;

  # ── Virtualisation ────────────────────────────────────────
  virtualisation.libvirtd.enable = true;
  programs.virt-manager.enable = true;

  programs.coolercontrol.enable = true;

  # ── User Packages ─────────────────────────────────────────
  users.users.${username} = {
    extraGroups = [ "plugdev" ];
    packages = (with pkgs; [
      # Codex needs user-selected project directories and host development tools.
      # A fixed NixPak file bind would block that core workflow.
      inputs.self.packages.${pkgs.system}.chatgpt
      blender
      inputs.self.packages.${pkgs.system}.codex
      inputs.self.packages.${pkgs.system}.claude-code
      browserUse
      wtype
      opencode
      hcxtools
      # mosquitto

      # Reverse engineering & security
      # metasploit
      # aircrack-ng
      # hashcat
      # hashcat-utils
      # wifite2

      # Internet & Communication
      qbittorrent

      # Media
      vlc
      loupe # GNOME image viewer (native, unsandboxed by request)

      scrcpy

      # Tools
      ethtool
      just
      nh
      rtk
      waycorner # hot-corner daemon for Wayland
    ]);
  };

  users.groups.plugdev = { };

  # ── Default image viewer (loupe) ──────────────────────────
  xdg.mime.defaultApplications =
    let
      loupe = "org.gnome.Loupe.desktop";
    in
    {
      "image/jpeg" = loupe;
      "image/png" = loupe;
      "image/gif" = loupe;
      "image/webp" = loupe;
      "image/tiff" = loupe;
      "image/bmp" = loupe;
      "image/svg+xml" = loupe;
      "image/avif" = loupe;
      "image/heif" = loupe;
      "image/heic" = loupe;
      "image/jxl" = loupe;
    };

  # ── System Packages ───────────────────────────────────────
  environment.systemPackages = with pkgs; [
    openssl
    yubikey-personalization
    fuse3
  ];


  # ── Udev Rules ────────────────────────────────────────────
  services.udev.packages = with pkgs; [
    libfido2
    yubikey-personalization
  ];
}
