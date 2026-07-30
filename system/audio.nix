# PipeWire audio stack.
{ pkgs, username, ... }:

let
  sampleRate = 44100; # mirrored in services/radio.nix (liquidsoap samplerate)
in
{
  # ── PipeWire ─────────────────────────────────────────────
  security.rtkit.enable = true; # Real-time scheduling for PipeWire
  services.pulseaudio.enable = false;

  services.pipewire = {
    enable = true;
    pulse.enable = true;
    jack.enable = true;
    alsa = {
      enable = true;
      support32Bit = true;
    };

    extraConfig.pipewire = {
      "92-low-latency"."context.properties" = {
        "default.clock.rate" = sampleRate;
        "default.clock.quantum" = 512;
        "default.clock.min-quantum" = 512;
        "default.clock.max-quantum" = 512;
      };
    };

    wireplumber.extraConfig."50-nvidia-hdmi-profile" = {
      "monitor.alsa.rules" = [
        {
          matches = [
            { "device.name" = "alsa_card.pci-0000_0a_00.1"; }
          ];
          actions.update-props = {
            "device.profile" = "output:hdmi-stereo-extra1";
          };
        }
        {
          matches = [
            { "node.name" = "alsa_output.pci-0000_0a_00.1.hdmi-stereo-extra1"; }
          ];
          actions.update-props = {
            "priority.session" = 50000;
          };
        }
      ];
    };
  };

  # ── User packages ────────────────────────────────────────
  users.users.${username}.packages = with pkgs; [
    pavucontrol
    alsa-scarlett-gui
  ];
}
