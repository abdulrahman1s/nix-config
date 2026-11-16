{ discord, lib, nodejs, vulkan-loader, ... }:

# Keep the official client and its pinned native modules. Enable its experimental
# NVIDIA encoder without replacing the rest of discord_voice with an older copy.
# https://github.com/relativemodder/discord-linux-vulkan-video-patcher
(discord.override {
  # NixPak supplies the outer filesystem sandbox; avoid a nested FHS environment.
  # Patching the ELF binaries means Discord's proprietary Krisp module may fail.
  useFHSEnv = false;
  disableUpdates = true;
}).overrideAttrs (old: {
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ nodejs ];

  postInstall = (old.postInstall or "") + ''
    voice="$out/opt/Discord/modules/discord_voice/index.js"

    # Fail on upstream API changes so an update cannot silently drop encoding.
    # Apply to both the media-host and in-process connection constructors.
    substituteInPlace "$voice" \
      --replace-fail \
        'function (userId, connectionOptions, onConnectCallback) {' \
        'function (userId, connectionOptions, onConnectCallback) {
          connectionOptions = {
            ...connectionOptions,
            experiments: [...new Set([...(connectionOptions?.experiments ?? []), "linux-vulkan"])],
          };' \
      --replace-fail \
        'setTransportOptions: (options) => instance.setTransportOptions(options),' \
        'setTransportOptions: (options) => {
          if (options != null && typeof options === "object") {
            const experiments = (options.videoEncoderExperiments ?? "")
              .split(",").map(value => value.trim())
              .filter(value => value && value !== "vaapi");
            options = {
              ...options,
              videoEncoderExperiments: [...new Set([
                ...experiments, "linux-nvenc", "useCaptureDeviceForEncode",
              ])].join(","),
            };
          }
          return instance.setTransportOptions(options);
        },' \
      --replace-fail \
        'setDesktopSourceWithOptions: (options) => instance.setDesktopSourceWithOptions(options),' \
        'setDesktopSourceWithOptions: (options) => instance.setDesktopSourceWithOptions({
          ...options, useCaptureDeviceForEncode: true,
        }),'

    chmod +x "$out/opt/Discord/modules/discord_voice/gpu_encoder_helper"
    node --check "$voice"
  '';

  # discord_voice/gpu_encoder_helper loads Vulkan dynamically; NVENC and CUDA
  # are supplied by /run/opengl-driver, exposed by the NixPak gpu preset.
  postFixup = (old.postFixup or "") + ''
    wrapProgram "$out/opt/Discord/Discord" \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ vulkan-loader ]}
  '';
})
