{ pkgs, username, ... }: {
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

  # Never print the sudo lecture. Its "already lectured this user" marker lives
  # in /var/db/sudo on the wiped root, so the default lecture=once would reprint
  # on the first sudo of every boot under impermanence.
  security.sudo.extraConfig = ''
    Defaults lecture=never
  '';

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
