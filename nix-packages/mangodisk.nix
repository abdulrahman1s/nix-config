{ lib, stdenv, fetchurl, dpkg, autoPatchelfHook, wrapGAppsHook3
, gtk3, webkitgtk_4_1, libsoup_3, glib, cairo, gdk-pixbuf, dbus
, libappindicator-gtk3, xdg-utils, mangodisk
}:

stdenv.mkDerivation rec {
  pname = "mangodisk";
  version = mangodisk.version;

  src = fetchurl {
    url = "https://github.com/harry0703/MangoDisk/releases/download/v${version}/MangoDisk-${version}-linux-x64.deb";
    hash = mangodisk.hash;
  };

  nativeBuildInputs = [ dpkg autoPatchelfHook wrapGAppsHook3 ];
  buildInputs = [
    gtk3 webkitgtk_4_1 libsoup_3 glib cairo gdk-pixbuf dbus stdenv.cc.cc.lib
  ];

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x "$src" .
    runHook postUnpack
  '';
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -r usr/bin usr/share "$out/"
    substituteInPlace "$out/share/applications/MangoDisk.desktop" \
      --replace-fail "Exec=MangoDisk" "Exec=$out/bin/MangoDisk" \
      --replace-fail "Categories=" "Categories=System;Filesystem;"
    runHook postInstall
  '';

  preFixup = ''
    gappsWrapperArgs+=(
      --prefix PATH : "${lib.makeBinPath [ xdg-utils ]}"
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ libappindicator-gtk3 ]}"
      --unset APPIMAGE
    )
  '';

  # The prebuilt app retains update checks, but Tauri's Linux self-updater
  # requires an AppImage. This unpacked .deb stays immutable in the Nix store;
  # update it through this expression instead of the application's updater.
  meta = {
    description = "Disk cleanup, storage analysis, and privacy protection";
    homepage = "https://github.com/harry0703/MangoDisk";
    license = lib.licenses.gpl3Only;
    platforms = [ "x86_64-linux" ];
    mainProgram = "MangoDisk";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
