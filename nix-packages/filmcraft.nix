{ lib, stdenv, fetchurl, autoPatchelfHook, makeWrapper, filmcraft, alsa-lib
, libGL, libxkbcommon, wayland, libx11, libxcb, vulkan-loader
}:

stdenv.mkDerivation rec {
  pname = "filmcraft";
  version = filmcraft.version;

  src = fetchurl {
    url = "https://github.com/storytold/filmcraft/releases/download/v${filmcraft.version}/filmcraft-${filmcraft.version}-linux-x86_64.tar.gz";
    hash = filmcraft.hash;
  };

  nativeBuildInputs = [ autoPatchelfHook makeWrapper ];
  buildInputs = [ alsa-lib libGL libxkbcommon wayland libx11 libxcb vulkan-loader stdenv.cc.cc.lib ];
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/libexec/filmcraft" "$out/share"
    install -m755 bin/filmcraft bin/filmcraft-cli "$out/libexec/filmcraft/"
    cp -r share/. "$out/share/"

    for binary in filmcraft filmcraft-cli; do
      makeWrapper "$out/libexec/filmcraft/$binary" "$out/bin/$binary" \
        --prefix LD_LIBRARY_PATH : "/run/opengl-driver/lib:${lib.makeLibraryPath buildInputs}"
    done
    runHook postInstall
  '';

  meta = {
    description = "Native nonlinear video editor";
    homepage = "https://github.com/storytold/filmcraft";
    license = with lib.licenses; [ asl20 mit ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "filmcraft";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
