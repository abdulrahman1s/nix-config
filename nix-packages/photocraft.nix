{ lib, stdenv, fetchurl, autoPatchelfHook, makeWrapper, photocraft
, libGL, libxkbcommon, wayland, libx11, libxcb, vulkan-loader
}:

stdenv.mkDerivation rec {
  pname = "photocraft";
  version = photocraft.version;

  src = fetchurl {
    url = "https://github.com/storytold/photocraft/releases/download/v${photocraft.version}/photocraft-${photocraft.version}-linux-x86_64.tar.gz";
    hash = photocraft.hash;
  };

  nativeBuildInputs = [ autoPatchelfHook makeWrapper ];
  buildInputs = [ libGL libxkbcommon wayland libx11 libxcb vulkan-loader stdenv.cc.cc.lib ];
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/libexec/photocraft" "$out/share"
    install -m755 bin/photocraft bin/photocraft-cli "$out/libexec/photocraft/"
    cp -r share/. "$out/share/"

    for binary in photocraft photocraft-cli; do
      makeWrapper "$out/libexec/photocraft/$binary" "$out/bin/$binary" \
        --prefix LD_LIBRARY_PATH : "/run/opengl-driver/lib:${lib.makeLibraryPath buildInputs}"
    done
    runHook postInstall
  '';

  meta = {
    description = "Native image editor with layered PSD support";
    homepage = "https://github.com/storytold/photocraft";
    license = with lib.licenses; [ asl20 mit ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "photocraft";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
