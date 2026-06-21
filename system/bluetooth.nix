# Bluetooth (Realtek RTL8761BU USB radio).
{ pkgs, ... }:

{
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings.General.Experimental = true;
  };

  # Why this exists: noctalia's Airplane Mode toggle runs `rfkill block all`
  # (Services/Networking/NetworkService.qml). That soft-blocks Wi-Fi *and*
  # Bluetooth. systemd-rfkill persists the block to /var/lib/systemd/rfkill/,
  # and that dir survives the per-boot root wipe because impermanence.nix
  # persists /var/lib/systemd — so one airplane-on freezes into /persist and is
  # replayed on every boot. Wi-Fi self-heals (NetworkManager unblocks the radios
  # it manages at startup); Bluetooth does not (powerOnBoot powers the adapter
  # but does NOT clear an rfkill block), so bluetoothd can't power it on and
  # drops the adapter — blank hci address, nothing on org.bluez. Net effect:
  # Bluetooth silently dead at boot while Wi-Fi looks fine, hiding the cause.
  # This oneshot runs after systemd-rfkill's restore and before bluetoothd, so
  # the radio is always unblocked by the time the daemon enumerates it.
  # (Toggling Airplane Mode on mid-session still works; this only runs at boot.)
  systemd.services.bluetooth-rfkill-unblock = {
    description = "Clear stale persisted rfkill soft-block on the Bluetooth radio";
    after = [ "systemd-rfkill.service" ];
    before = [ "bluetooth.service" ];
    wantedBy = [ "bluetooth.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.util-linux}/bin/rfkill unblock bluetooth";
    };
  };
}
