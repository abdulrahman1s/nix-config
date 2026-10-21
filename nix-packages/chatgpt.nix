{ pkgs, chatgpt }:

let
  # Electron's library paths must not leak into the browser or its sandbox.
  cleanXdgOpen = pkgs.writeShellScriptBin "xdg-open" ''
    unset LD_LIBRARY_PATH GIO_EXTRA_MODULES GDK_PIXBUF_MODULE_FILE
    exec ${pkgs.xdg-utils}/bin/xdg-open "$@"
  '';
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "chatgpt";
  inherit (chatgpt) version;

  src = pkgs.fetchurl {
    url = "https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt/chatgpt_${chatgpt.version}_amd64.deb";
    hash = chatgpt.hash;
  };

  nativeBuildInputs = with pkgs; [
    autoPatchelfHook
    asar
    dpkg
    makeWrapper
    wrapGAppsHook3
  ];

  buildInputs = with pkgs; [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    gdk-pixbuf
    glib
    gtk3
    libdrm
    libgbm
    libGL
    libnotify
    libsecret
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

  # libudev is loaded with dlopen by bundled native helpers.
  runtimeDependencies = [ (pkgs.lib.getLib pkgs.systemd) ];

  # Extract the app without running the Debian postinst that adds an apt repo.
  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x "$src" source
    runHook postUnpack
  '';

  dontBuild = true;
  dontStrip = true;
  dontWrapGApps = true;

  # patchelf moves the ELF interpreter beyond detect-libc's 2 KiB read.
  # Without /usr/bin/ldd on NixOS, Parcel's Git worker then falls back to
  # process.report.getReport(), which traps in the bundled Electron runtime.
  # Give both the bundled and standalone detectors a real glibc ldd path.
  postPatch = ''
    resources=source/usr/lib/chatgpt/resources
    asar extract "$resources/app.asar" app
    substituteInPlace \
      app/.vite/build/watcher-*.js \
      app/node_modules/@parcel/watcher/node_modules/detect-libc/lib/filesystem.js \
      --replace-fail /usr/bin/ldd ${pkgs.glibc.bin}/bin/ldd
    asar pack app "$resources/app.asar" --unpack '**/*.node'
    rm -r app
  '';

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
    ln -s ../lib/chatgpt/ChatGPT "$out/bin/chatgpt"
    substituteInPlace "$out/share/applications/chatgpt.desktop" \
      --replace-fail "Exec=chatgpt %U" "Exec=$out/bin/chatgpt %U"
    runHook postInstall
  '';

  # Wrap the real entry point so the bundled codex-launcher gets the same
  # GTK resources and runtime libraries as the desktop launcher.
  postFixup = ''
    wrapProgram "$out/lib/chatgpt/ChatGPT" \
      "''${gappsWrapperArgs[@]}" \
      --prefix LD_LIBRARY_PATH : "${pkgs.addDriverRunpath.driverLink}/lib:${pkgs.lib.makeLibraryPath [ pkgs.libGL pkgs.mesa pkgs.libgbm pkgs.libsecret ]}" \
      --prefix PATH : "${pkgs.lib.makeBinPath [ cleanXdgOpen pkgs.xdg-utils ]}" \
      --prefix XDG_DATA_DIRS : "${pkgs.addDriverRunpath.driverLink}/share"
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
