{ stdenv, lib, fetchurl, dpkg, autoPatchelfHook
, dbus, libglvnd, libx11, libxcb, libxcursor, libxi, libxkbcommon, libxrender
, vulkan-loader, wayland
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "misterdownloadmanager";
  version = "0.5.2";

  # The .deb carries the desktop entry and icon that the plain tarball lacks.
  src = fetchurl {
    url = "https://github.com/anefzaoui/misterdownloadmanager/releases/download/v${finalAttrs.version}/MisterDownloadManager-${finalAttrs.version}-linux-x86_64.deb";
    hash = "sha256-nTMNloSggZzqmHyudgGxxQePx3Uglepuay8v7wNakuE=";
  };

  nativeBuildInputs = [ dpkg autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib ];
  # winit, wgpu/glow, the tray and rfd's portal client dlopen these at runtime;
  # autoPatchelf adds them to every binary's RUNPATH.
  runtimeDependencies = [
    dbus
    libglvnd
    libx11
    libxcb
    libxcursor
    libxi
    libxkbcommon
    libxrender
    vulkan-loader
    wayland
  ];

  dontBuild = true;
  dontStrip = true;

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x "$src" .
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    # Keep the programs together: the CLI launcher runs the app beside itself.
    for program in misterdownloadmanager misterdownloadmanager-cli misterdownloadmanager-mcp; do
      install -Dm755 "usr/bin/$program" "$out/bin/$program"
    done
    # The browser host starts a `misterdownloadmanager` beside itself when the
    # app is not running. Keep it apart so a wrapper decides how that happens.
    install -Dm755 usr/bin/misterdownloadmanager-nmhost \
      "$out/libexec/misterdownloadmanager-host/misterdownloadmanager-nmhost"

    install -Dm644 usr/share/applications/misterdownloadmanager.desktop \
      "$out/share/applications/misterdownloadmanager.desktop"
    install -Dm644 usr/share/icons/hicolor/256x256/apps/misterdownloadmanager.png \
      "$out/share/icons/hicolor/256x256/apps/misterdownloadmanager.png"
    mkdir -p "$out/share/misterdownloadmanager"
    cp -r usr/share/misterdownloadmanager/extension-chromium "$out/share/misterdownloadmanager/"
    cp usr/share/misterdownloadmanager/mdm-firefox.xpi "$out/share/misterdownloadmanager/"

    runHook postInstall
  '';

  meta = {
    description = "Open-source download manager with torrent, video and browser integration";
    homepage = "https://github.com/anefzaoui/misterdownloadmanager";
    license = lib.licenses.gpl3Only;
    mainProgram = "misterdownloadmanager";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
