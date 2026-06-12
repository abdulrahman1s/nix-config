settings.frame.audio.samplerate := 44100

radio = mksafe(input.pulseaudio(device="RadioSink.monitor"))

output.harbor(
  %mp3(bitrate=128, stereo=true),
  mount="/stream.mp3",
  port=4444,
  radio
)
