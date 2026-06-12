# Liquidsoap internet radio stream, fed by a dedicated PipeWire null sink.
{ pkgs, ... }:

let
  radioPort = 4444;
  # Must match `default.clock.rate` (sampleRate) in system/audio.nix.
  sampleRate = 44100;
  hardening = import ../system/hardening.nix;

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
  # Dedicated null sink the stream reads from; it lives in PipeWire's graph
  # but exists solely for the radio, so it rides along here via module merge.
  services.pipewire.extraConfig.pipewire."99-radio-sink"."context.objects" = [
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
    } // hardening // {
      # Sandboxing — limit blast radius if liquidsoap is compromised.
      # Shared baseline in ../system/hardening.nix; below are radio-specific keys.
      ProtectHome = "tmpfs";
      StateDirectory = "liquidsoap";
      RuntimeDirectory = "liquidsoap";
      ReadWritePaths = [ "%t/pulse" ];
      RestrictSUIDSGID = true;
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
      CapabilityBoundingSet = "";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
      SystemCallArchitectures = "native";
    };
  };
}
