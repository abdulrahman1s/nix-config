{ ... }:

{
  # ── Avahi / mDNS ──────────────────────────────────────────
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    settings.publish = {
      disable-publishing = false;
      publish-addresses = true;
      publish-workstation = true;
      disable-user-service-publishing = false;
    };
  };
}
