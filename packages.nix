{ pkgs, username, inputs, ... }:
{


  # ── Nix LD (dynamic library fix for unpackaged binaries) ───
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    libGL
    libz
  ];


  # ── Virtualisation ────────────────────────────────────────
  virtualisation.libvirtd.enable = true;
  programs.virt-manager.enable = true;


  # ── User Packages ─────────────────────────────────────────
  users.users.${username} = {
    extraGroups = [ "plugdev" ];
    packages = with pkgs; [
      inputs.brave-previews.packages.${pkgs.stdenv.hostPlatform.system}.brave-origin-nightly

      hcxtools
      #   (hashcat.override {
      #    cudaSupport = true;
      #  })

      kiwix
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
      # orca-slicer

      # Tools
      ethtool
      scrcpy
      just
      nh


      waycorner # hot-corner daemon for Wayland
      signal-desktop
    ];
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
