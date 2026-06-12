# Baseline systemd unit hardening shared by long-running network services.
# Spread with `//` then override per-service (e.g. ProtectHome, address families).
{
  NoNewPrivileges = true;
  ProtectSystem = "strict";
  PrivateTmp = true;
  PrivateDevices = true;
  ProtectKernelTunables = true;
  ProtectKernelModules = true;
  ProtectControlGroups = true;
  ProtectClock = true;
  ProtectHostname = true;
  LockPersonality = true;
  RestrictNamespaces = true;
}
