{ pkgs, config, inputs, username, ... }:
{
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  services.xserver.enable = true;
  services.displayManager.ly.enable = true;
  services.xserver.videoDrivers = [ "nvidia" ];

  # fbcon uses the smallest connected mode for its visible surface. Give both
  # outputs a common 4K boot mode so Ly can center against the full framebuffer.
  boot.kernelParams = [
    "video=DP-3:3840x2160@60"
    "video=HDMI-A-1:3840x2160@60"
  ];
  console = {
    font = "ter-v32n";
    packages = [ pkgs.terminus_font ];
  };

  # ── Niri (scrollable tiling Wayland compositor) ──────────
  programs.niri.enable = true;




  # Desktop apps
  users.users.${username}.packages = with pkgs; [
    gnome-calculator
    gnome-disk-utility
    gnome-logs
    baobab
    gparted
    mission-center
    gnome-pomodoro
    gnome-text-editor
    nautilus

    cliphist # Needed for https://noctalia.dev/plugins/clipboard/
    linux-wallpaperengine # Live wallpaper
    nwg-look # GTK settings


    zbar # Barcode scanner
    imagemagick
    grim
    tesseract
    gifski
    jq
    slurp
    wl-screenrec

    xdg-desktop-portal
    vicinae # Launcher
  ];

  # Needed for nautilus to mount partitions 
  services.udisks2.enable = true;
  services.gvfs.enable = true;

  programs.gpu-screen-recorder.enable = true;


  # ── Noctalia Shell (panel/shell for niri) ────────────────
  environment.systemPackages = [
    inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default
    pkgs.wl-clipboard
    pkgs.xwayland-satellite
    pkgs.adw-gtk3
  ];

  hardware.nvidia = {
    open = true;
    nvidiaSettings = true;
    nvidiaPersistenced = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  # Reduce niri VRAM usage by disabling NVIDIA's free buffer pool reuse
  # https://github.com/niri-wm/niri/wiki/Nvidia
  environment.etc."nvidia/nvidia-application-profiles-rc.d/50-limit-free-buffer-pool-in-wayland-compositors.json".text = builtins.toJSON {
    rules = [
      {
        pattern = {
          feature = "procname";
          matches = "niri";
        };
        profile = "Limit Free Buffer Pool On Wayland Compositors";
      }
    ];
    profiles = [
      {
        name = "Limit Free Buffer Pool On Wayland Compositors";
        settings = [
          {
            key = "GLVidHeapReuseRatio";
            value = 0;
          }
        ];
      }
    ];
  };

  hardware.nvidia-container-toolkit.enable = true;

  # nixpkgs.config.cudaSupport = true;

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [ mangohud nvidia-vaapi-driver ];
    extraPackages32 = with pkgs; [ pkgsi686Linux.mangohud ];
  };

  programs.nautilus-open-any-terminal = {
    enable = true;
    terminal = "ghostty";
  };
}
