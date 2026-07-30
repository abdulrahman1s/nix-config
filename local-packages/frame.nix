{ lib
, stdenv
, fetchurl
, autoPatchelfHook
, makeWrapper
, alsa-lib
, ffmpeg
, fontconfig
, freetype
, libdrm
, libGL
, libx11
, libxkbcommon
, vulkan-loader
, wayland
}:

let
  version = "0.32.0";

  runtimeLibraries = [
    alsa-lib
    fontconfig
    freetype
    libdrm
    libGL
    libx11
    libxkbcommon
    stdenv.cc.cc.lib
    vulkan-loader
    wayland
  ];
in
stdenv.mkDerivation {
  pname = "frame";
  inherit version;

  src = fetchurl {
    url = "https://github.com/66HEX/frame/releases/download/${version}/frame-linux-x86_64.tar.gz";
    hash = "sha256-p+phRFaxhM+86vhB9pfhv/MT5vd0/FObiqAHEVz3vFU=";
  };

  sourceRoot = ".";

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ];

  buildInputs = runtimeLibraries;

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -a frame.app/. $out
    rm -rf $out/bin/binaries

    substituteInPlace $out/share/applications/Frame.desktop \
      --replace-fail 'TryExec=frame' "TryExec=$out/bin/frame" \
      --replace-fail 'Exec=frame' "Exec=$out/bin/frame"

    runHook postInstall
  '';

  postFixup = ''
    wrapProgram $out/bin/frame \
      --prefix PATH : ${lib.makeBinPath [ ffmpeg ]} \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath runtimeLibraries} \
      --set FRAME_USE_SYSTEM_MEDIA_TOOLS 1 \
      --set FRAME_UPDATE_EXPLANATION 'This NixOS package is managed by the system configuration. Install updates by updating the package expression and rebuilding.'
  '';

  meta = {
    description = "Native desktop interface for FFmpeg media conversion";
    homepage = "https://github.com/66HEX/frame";
    changelog = "https://github.com/66HEX/frame/blob/${version}/CHANGELOG.md";
    license = lib.licenses.gpl3Only;
    mainProgram = "frame";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
