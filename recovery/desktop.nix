# Mouse-driven recovery desktop: labwc with titlebar buttons and a right-click
# root menu, plus an always-visible Noctalia bar and dock. Every repair tool
# has a menu and launcher entry, so no shortcut has to be known.
{ inputs, lib, pkgs, username, ... }:
let
  brave = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.brave-origin;
  labwcThemes = pkgs.callPackage ../local-packages/labwc-themes.nix { };

  # Built against this system's nixpkgs. The Noctalia flake's own package brings
  # a second copy of glibc, Qt and the rest of its closure, about 800 MiB.
  noctalia = pkgs.callPackage "${inputs.noctalia}/nix/package.nix" {
    rev = inputs.noctalia.shortRev or "unknown";
  };

  # Runs one tool as root in its own window and keeps the output readable.
  recoveryAction = pkgs.writeShellApplication {
    name = "recovery-action";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ./scripts/recovery-action.sh;
  };

  displays = pkgs.writeShellApplication {
    name = "recovery-displays";
    runtimeInputs = with pkgs; [
      jq
      wlr-randr
    ];
    text = builtins.readFile ./scripts/recovery-displays.sh;
  };

  # GNOME's own dark Adwaita background, the companion of labAdwaita-dark.
  # Copying the one file keeps the other GNOME backgrounds out of the closure.
  wallpaper = pkgs.runCommand "adwaita-dark-wallpaper" { } ''
    install -Dm444 ${pkgs.gnome-backgrounds}/share/backgrounds/gnome/adwaita-d.jxl "$out"
  '';

  terminalAction = action: action // {
    exec = ''${pkgs.foot}/bin/foot --app-id=recovery-action --window-size-chars=110x34 --title="${action.title}" ${recoveryAction}/bin/recovery-action ${action.command}'';
  };

  recoveryTools = map terminalAction [
    {
      name = "recovery-enter-main";
      title = "Enter Main System";
      icon = "nix-snowflake";
      command = "system-chroot";
    }
    {
      name = "recovery-repair-bootloader";
      title = "Repair Main Bootloader";
      icon = "application-x-firmware";
      command = "system-chroot --reinstall-bootloader";
    }
    {
      name = "recovery-main-logs";
      title = "Main System Logs";
      icon = "text-x-generic";
      command = "main-logs";
    }
    {
      name = "recovery-disk-health";
      title = "Disk Health";
      icon = "drive-multidisk";
      command = "disk-health";
    }
  ] ++ [
    {
      name = "recovery-system-monitor";
      title = "System Monitor";
      icon = "btop";
      exec = ''${pkgs.foot}/bin/foot --window-size-chars=140x40 --title="System Monitor" ${pkgs.btop}/bin/btop'';
    }
    {
      name = "recovery-guide";
      title = "Recovery Guide";
      icon = "text-html";
      exec = "${brave}/bin/brave-origin file:///etc/nixos-recovery/guide.html";
    }
  ];

  # Signed in by recovery-update; see recovery/shell.nix.
  assistants = [
    {
      name = "recovery-claude";
      title = "Claude Code";
      icon = "text-x-script";
      exec = ''${pkgs.foot}/bin/foot --title="Claude Code" claude'';
    }
    {
      name = "recovery-codex";
      title = "Codex";
      icon = "text-x-script";
      exec = ''${pkgs.foot}/bin/foot --title="Codex" codex'';
    }
  ];

  applications = [
    { title = "Terminal (Ghostty)"; icon = "com.mitchellh.ghostty"; exec = "ghostty"; }
    { title = "Terminal (Foot)"; icon = "foot"; exec = "foot"; }
    { title = "Files"; icon = "folder"; exec = "pcmanfm"; }
    { title = "Partition Editor"; icon = "gparted"; exec = "gparted"; }
    { title = "Web Browser"; icon = "brave-origin"; exec = "brave-origin"; }
  ];

  menuItem = { title, icon, exec, ... }:
    ''    <item label="${lib.escapeXML title}" icon="${icon}"><action name="Execute"><command>${lib.escapeXML exec}</command></action></item>'';

  # Right click on the desktop.
  rootMenu = pkgs.writeText "labwc-menu.xml" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <openbox_menu>
      <menu id="root-menu" label="">
        <separator label="Recovery" />
    ${lib.concatMapStringsSep "\n" menuItem recoveryTools}
        <separator label="Assistants" />
    ${lib.concatMapStringsSep "\n" menuItem assistants}
        <separator label="Applications" />
    ${lib.concatMapStringsSep "\n" menuItem applications}
        <separator />
        <item label="Reboot" icon="system-reboot-symbolic"><action name="Execute"><command>systemctl reboot</command></action></item>
        <item label="Reboot to Firmware Setup" icon="system-reboot-symbolic"><action name="Execute"><command>systemctl reboot --firmware-setup</command></action></item>
        <item label="Shut Down" icon="system-shutdown-symbolic"><action name="Execute"><command>systemctl poweroff</command></action></item>
        <item label="Log Out" icon="system-log-out-symbolic"><action name="Exit" /></item>
      </menu>
    </openbox_menu>
  '';

  desktopItems = map
    (tool: pkgs.makeDesktopItem {
      inherit (tool) name icon exec;
      desktopName = tool.title;
      categories = [ "System" ];
    })
    (recoveryTools ++ assistants);
in
{
  programs.labwc.enable = true;

  # Ghostty's desktop entry is D-Bus activated, so the dock and launcher need
  # its service files to open it. labwc ships labwc-session.target, which its
  # autostart file starts.
  services.dbus.packages = [ pkgs.ghostty ];
  systemd.packages = [
    pkgs.ghostty
    pkgs.labwc
  ];

  # The Brave wrapper only uses native Wayland when this is set.
  environment.sessionVariables.NIXOS_OZONE_WL = "1";

  systemd.user.services.noctalia = {
    description = "Noctalia desktop shell";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    unitConfig.StartLimitIntervalSec = 0;
    # The generated unit's PATH overrides the user manager's PATH; Noctalia
    # needs these to launch applications and polkit helpers.
    path = [
      "/run/wrappers"
      "/etc/profiles/per-user/${username}"
      "/run/current-system/sw"
    ];
    # Without the bar and dock the desktop is down to the root menu, so always
    # bring them back.
    serviceConfig = {
      Type = "simple";
      ExecStart = "${noctalia}/bin/noctalia";
      Restart = "on-failure";
      RestartSec = 2;
    };
  };

  # labwc reads /etc/xdg/labwc when ~/.config/labwc has no file of that name.
  environment.etc = {
    "xdg/labwc/rc.xml".source = ./config/labwc/rc.xml;
    "xdg/labwc/menu.xml".source = rootMenu;
    "xdg/labwc/autostart".source = ./config/labwc/autostart;
    "xdg/labwc/shutdown".source = ./config/labwc/shutdown;
    "xdg/labwc/environment".source = ./config/labwc/environment;
    "nixos-recovery/noctalia/config.toml".source = ./config/noctalia/config.toml;
    # Colors taken from labAdwaita-dark, so the bar and dock match the windows.
    "nixos-recovery/noctalia/labAdwaita-dark.json".source = ./config/noctalia/labAdwaita-dark.json;
    "nixos-recovery/wallpaper.jxl".source = wallpaper;
    "nixos-recovery/foot.ini".source = ./config/foot.ini;
    "nixos-recovery/readme.txt".source = ./docs/readme.txt;
    "nixos-recovery/guide.html".source = ./docs/guide.html;
  };

  system.userActivationScripts.recovery-desktop-config.text = ''
    link_config() {
      if [[ -e $2 && ! -L $2 ]]; then
        mv -- "$2" "$2.$(date +%s).bak"
      fi
      ln -sfn "$1" "$2"
    }

    install -d -m 0755 "$HOME/.config/noctalia/palettes" "$HOME/.config/foot"

    # Earlier versions used niri and linked its config and helper scripts here.
    for link in "$HOME"/.config/niri/*; do
      if [[ -L $link && ! -e $link && $(readlink "$link") == /etc/nixos-recovery/* ]]; then
        rm -f -- "$link"
      fi
    done

    link_config /etc/nixos-recovery/noctalia/config.toml "$HOME/.config/noctalia/config.toml"
    # Noctalia only looks for custom palettes in its config directory.
    link_config /etc/nixos-recovery/noctalia/labAdwaita-dark.json "$HOME/.config/noctalia/palettes/labAdwaita-dark.json"
    # The shell tools cheat sheet, where a terminal and the file manager open.
    link_config /etc/nixos-recovery/readme.txt "$HOME/readme.txt"

    # Noctalia's theme hook adds its include to the user's foot.ini, so this one
    # is created once and owned by the user rather than linked to /etc.
    if [[ ! -e $HOME/.config/foot/foot.ini ]]; then
      printf '[main]\ninclude=/etc/nixos-recovery/foot.ini\n' >"$HOME/.config/foot/foot.ini"
    fi
  '';

  environment.systemPackages = [
    noctalia
    labwcThemes
    recoveryAction
    displays
    # Native GUI packages are intentional here because this separate repair
    # installation does not have the main system's NixPak runtime or profile paths.
    brave
    # Foot renders in software and remains usable if Ghostty's GPU renderer fails.
    pkgs.foot
    pkgs.ghostty
    pkgs.gparted
    pkgs.pcmanfm
    # Icons for GTK apps, menus, the cursor, and the recovery launcher entries.
    pkgs.adwaita-icon-theme
    pkgs.nixos-icons
  ] ++ desktopItems;
}
