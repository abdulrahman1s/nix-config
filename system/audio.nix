# PipeWire audio stack and internet radio streaming.
{ pkgs, username, ... }:

let
  sampleRate = 44100;
  radioPort = 4444;

  # Generate liquidsoap config from Nix so sampleRate stays in sync
  # with PipeWire's default.clock.rate above.
  radioConfig = pkgs.writeText "radio.liq" ''
    settings.frame.audio.samplerate := ${toString sampleRate}

    radio = mksafe(input.pulseaudio(device="RadioSink.monitor"))

    output.harbor(
      %mp3(bitrate=128, stereo=true),
      mount="/stream.mp3",
      port=${toString radioPort},
      radio
    )
  '';

  pulseClientConfig = pkgs.writeText "radio-pulse-client.conf" ''
    autospawn = no
  '';
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

      "99-radio-sink"."context.objects" = [
        {
          factory = "adapter";
          args = {
            "factory.name" = "support.null-audio-sink";
            "node.name" = "RadioSink";
            "node.description" = "Stream to Internet Radio";
            "media.class" = "Audio/Sink";
            "audio.position" = "FL,FR";
          };
        }
      ];
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
      ];
    };
  };

  # ── Liquidsoap internet radio ────────────────────────────
  # Runs as a user service so it has access to PipeWire's RadioSink.
  systemd.user.services.radio = {
    description = "Liquidsoap internet radio stream";
    after = [ "pipewire.service" "pipewire-pulse.service" ];
    requires = [ "pipewire-pulse.service" ];
    wantedBy = [ "default.target" ];

    serviceConfig = {
      ExecStart = "${pkgs.liquidsoap}/bin/liquidsoap ${radioConfig}";
      Environment = "PULSE_CLIENTCONFIG=${pulseClientConfig}";
      Restart = "on-failure";
      RestartSec = 5;

      # Sandboxing — limit blast radius if liquidsoap is compromised
      NoNewPrivileges = true;
      ProtectHome = "tmpfs";
      ProtectSystem = "strict";
      StateDirectory = "liquidsoap";
      RuntimeDirectory = "liquidsoap";
      ReadWritePaths = [ "%t/pulse" ];
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectClock = true;
      ProtectHostname = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictNamespaces = true;
      RestrictSUIDSGID = true;
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
      LockPersonality = true;
      CapabilityBoundingSet = "";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
      SystemCallArchitectures = "native";
    };
  };

  # ── User packages ────────────────────────────────────────
  users.users.${username}.packages = with pkgs; [
    pavucontrol
    alsa-scarlett-gui
  ];
}
