{ pkgs, username, ... }:
let
  controllerNode = pkgs.writeShellScript "sandbox-controller-node" ''
    set -eu
    action=$1 major=$2 minor=$3 device=$4
    case "$major:$minor" in *[!0-9:]*|:*|*:) exit 1 ;; esac
    case "$device" in event[0-9]*) ;; *) exit 1 ;; esac
    node="/dev/sandbox-input/$device"
    case "$action" in
      add)
        ${pkgs.coreutils}/bin/install -d -m 0755 -o root -g root /dev/sandbox-input
        if [ ! -e "$node" ]; then
          ${pkgs.coreutils}/bin/mknod "$node" c "$major" "$minor"
        fi
        ${pkgs.coreutils}/bin/chown ${username}:users "$node"
        ${pkgs.coreutils}/bin/chmod 0600 "$node"
        ;;
      remove) ${pkgs.coreutils}/bin/rm -f -- "$node" ;;
    esac
  '';
in
{
  # The persisted file may predate this policy and retain mode 0644.
  system.userActivationScripts.shell-secret-permissions.text = ''
    if [ -f "$HOME/.zsh_secrets" ] && [ ! -L "$HOME/.zsh_secrets" ]; then
      ${pkgs.coreutils}/bin/chmod 0600 "$HOME/.zsh_secrets"
    fi
    for private_dir in ".codex" ".config/opencode" ".local/share/opencode" ".local/state/opencode" ".local/share/vicinae"; do
      if [ -d "$HOME/$private_dir" ] && [ ! -L "$HOME/$private_dir" ]; then
        ${pkgs.coreutils}/bin/chmod 0700 "$HOME/$private_dir"
      fi
    done
  '';

  # A separate device tree allows controller hotplug without exposing keyboards.
  systemd.tmpfiles.rules = [ "d /dev/sandbox-input 0755 root root -" ];
  services.udev.extraRules = ''
    ACTION=="add|remove", SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_JOYSTICK}=="1", RUN+="${controllerNode} $env{ACTION} %M %m %k"
  '';
  # Copy Fail: root on virtually any Linux
  boot.blacklistedKernelModules = [
    "algif_aead"
  ];

  security.pam.u2f = {
    enable = false;
    settings = {
      # 'cue' tells the system to send a message like "Touch your security key"
      cue = true;
    };
  };
  security.pam.services.sudo.u2f.enable = true;

  security.sudo.enable = false;
  security.sudo-rs = {
    enable = true;
    wheelNeedsPassword = true;
  };

  systemd.services.sandbox-hidraw-devices = {
    description = "Create stable hidraw nodes for sandbox hotplug";
    wantedBy = [ "multi-user.target" ];
    before = [ "display-manager.service" ];
    after = [ "systemd-modules-load.service" "systemd-udevd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      major=$(${pkgs.gawk}/bin/awk '$2 == "hidraw" { print $1; exit }' /proc/devices)
      if [ -z "$major" ]; then
        ${pkgs.kmod}/bin/modprobe hidraw || true
        major=$(${pkgs.gawk}/bin/awk '$2 == "hidraw" { print $1; exit }' /proc/devices)
      fi

      if [ -z "$major" ]; then
        echo "hidraw character-device major is unavailable" >&2
        exit 1
      fi

      ${pkgs.coreutils}/bin/install -d -m 0755 /dev/hidraw-proxy
      for minor in $(${pkgs.coreutils}/bin/seq 0 20); do
        node="/dev/hidraw-proxy/hidraw$minor"
        if [ ! -e "$node" ]; then
          ${pkgs.coreutils}/bin/mknod "$node" c "$major" "$minor"
        fi
        ${pkgs.coreutils}/bin/chown ${username}:users "$node"
        ${pkgs.coreutils}/bin/chmod 0600 "$node"
      done
    '';
  };

  security.polkit.enable = true;

  systemd.user.services.polkit-gnome-authentication-agent-1 = {
    description = "GNOME polkit authentication agent";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
      Restart = "on-failure";
    };
  };
}
