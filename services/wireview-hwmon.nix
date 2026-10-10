{ config, pkgs, username, ... }:

let
  wireviewHwmon = pkgs.callPackage ../local-packages/wireview-hwmon.nix {
    kernel = config.boot.kernelPackages.kernel;
  };
in
{
  boot.extraModulePackages = [ wireviewHwmon ];
  boot.kernelModules = [ "wireview_hwmon" ];

  environment.systemPackages = [ wireviewHwmon ];
  users.groups.wireview = { };
  users.users.${username}.extraGroups = [ "wireview" ];

  # ModemManager otherwise probes the WireView serial port and can hold it
  # while wireviewd tries to connect.
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="0483", ATTR{idProduct}=="5740", ENV{ID_MM_DEVICE_IGNORE}="1"
    SUBSYSTEM=="tty", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="5740", ENV{ID_MM_PORT_IGNORE}="1"
  '';

  systemd.services.wireviewd = {
    description = "WireView Pro II hwmon daemon";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" "systemd-modules-load.service" ];
    serviceConfig = {
      ExecStart = "${wireviewHwmon}/bin/wireviewd";
      Restart = "on-failure";
      RestartSec = 5;

      ProtectSystem = "strict";
      ReadWritePaths = [ "/run" ];
      LogsDirectory = "wireview";
      LogsDirectoryMode = "0750";
      ProtectHome = true;
      PrivateTmp = true;
      UMask = "0077";
      DevicePolicy = "closed";
      DeviceAllow = [ "char-ttyACM rw" "char-misc w" ];
      CapabilityBoundingSet = "";
      NoNewPrivileges = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      PrivateIPC = true;
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
      SystemCallErrorNumber = "EPERM";
    };
  };
}
