{ pkgs, chatgpt }:

pkgs.stdenvNoCC.mkDerivation {
  pname = "chatgpt";
  inherit (chatgpt) version;

  src = pkgs.fetchurl {
    url = "https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt/chatgpt_${chatgpt.version}_amd64.deb";
    hash = chatgpt.hash;
  };

  nativeBuildInputs = with pkgs; [
    autoPatchelfHook
    dpkg
    makeWrapper
  ];

  buildInputs = with pkgs; [
    alsa-lib
    at-spi2-atk
    atk
    cairo
    cups
    dbus
    expat
    gdk-pixbuf
    glib
    gtk3
    libdrm
    libGL
    libnotify
    libusb1
    libx11
    libxkbcommon
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxrandr
    mesa
    nspr
    nss
    openssl
    pango
    stdenv.cc.cc.lib
    systemd
    tpm2-tss
    zlib
  ];

  # Extract the app without running the Debian postinst that adds an apt repo.
  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x "$src" source
    runHook postUnpack
  '';

  dontBuild = true;
  dontStrip = true;
  # Both optional file-picker shims are bundled, but Qt 5 and Qt 6 setup
  # hooks cannot coexist as build inputs.
  preFixup = ''
    addAutoPatchelfSearchPath ${pkgs.qt5.qtbase}/lib
    addAutoPatchelfSearchPath ${pkgs.qt6.qtbase}/lib
  '';
  # The Debian archive also bundles musl-only Node addons; Electron selects
  # their glibc counterparts on this system.
  autoPatchelfIgnoreMissingDeps = [ "libc.musl-x86_64.so.1" ];

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib" "$out/bin" "$out/share"
    cp -a source/usr/lib/chatgpt "$out/lib/"
    cp -a source/usr/share/applications source/usr/share/pixmaps "$out/share/"
    makeWrapper "$out/lib/chatgpt/ChatGPT" "$out/bin/chatgpt" \
      --prefix LD_LIBRARY_PATH : "/run/opengl-driver/lib:${pkgs.lib.makeLibraryPath [ pkgs.libGL pkgs.mesa ]}"
    runHook postInstall
  '';

  meta = with pkgs.lib; {
    description = "OpenAI ChatGPT desktop app with Codex";
    homepage = "https://learn.chatgpt.com/docs/linux/linux-app";
    license = licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "chatgpt";
    sourceProvenance = [ sourceTypes.binaryNativeCode ];
  };
}
