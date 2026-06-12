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
   # (pkgs.callPackage ./packages/nekoray-bin { })

    # Media
      vlc
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

  # ── System Packages ───────────────────────────────────────
  environment.systemPackages = with pkgs; [
    openssl
    yubikey-personalization
    fuse3
    rclone
  ];


  # ── Udev Rules ────────────────────────────────────────────
  services.udev.packages = with pkgs; [
    libfido2
    yubikey-personalization
  ];
}
