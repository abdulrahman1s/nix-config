{ pkgs, ... }: {

  # "USB multiplexing daemon". This daemon is in charge of multiplexing connections over USB to an iOS device.
  services.usbmuxd.enable = true;


  environment.systemPackages = with pkgs; [
    gvfs # Gnome Virtual File System
    libimobiledevice # iOS device support
    ifuse # iOS filesystem mount
    uxplay # Apple Airplay receiver
  ];
}
