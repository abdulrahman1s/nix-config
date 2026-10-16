{ lib, stdenv, fetchurl, dpkg, autoPatchelfHook, wrapGAppsHook3
, gtk3, webkitgtk_4_1, libsoup_3, glib, cairo, gdk-pixbuf, dbus
, curl, vulkan-loader, libappindicator-gtk3, ffmpeg, git, xdg-utils
}:

stdenv.mkDerivation rec {
  pname = "digup";
  version = "0.7.0-beta.1";

  src = fetchurl {
    url = "https://github.com/ARahim3/DigUp/releases/download/v${version}/DigUp_${version}_amd64.deb";
    hash = "sha256-dUgSnrF18QySP1vlRBJ5mb4A76BwSypITdwBoUwCP00=";
  };

  nativeBuildInputs = [ dpkg autoPatchelfHook wrapGAppsHook3 ];
  buildInputs = [
    gtk3 webkitgtk_4_1 libsoup_3 glib cairo gdk-pixbuf dbus curl
    vulkan-loader stdenv.cc.cc.lib
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
    cp -r usr/bin usr/lib usr/share "$out/"
    # The helper supports ffmpeg beside itself; use the Nix-managed tools.
    rm "$out/lib/DigUp/helper/ffmpeg" "$out/lib/DigUp/helper/ffprobe"
    ln -s ${ffmpeg}/bin/ffmpeg "$out/lib/DigUp/helper/ffmpeg"
    ln -s ${ffmpeg}/bin/ffprobe "$out/lib/DigUp/helper/ffprobe"
    runHook postInstall
  '';

  preFixup = ''
    addAutoPatchelfSearchPath "$out/lib/DigUp/helper"
    gappsWrapperArgs+=(
      --add-flags "--helper $out/lib/DigUp/helper/digup"
      --prefix PATH : "${lib.makeBinPath [ ffmpeg git xdg-utils ]}"
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ libappindicator-gtk3 vulkan-loader ]}"
    )
  '';

  # The Debian build only offers a release-page link; it cannot install updates.
  meta = {
    description = "On-device semantic search for documents, images, audio, video and code";
    homepage = "https://github.com/ARahim3/DigUp";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "digup-shell";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
