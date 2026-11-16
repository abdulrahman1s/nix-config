{ lib, stdenvNoCC, requireFile, pkgsCross, python3, makeWrapper
, makeDesktopItem, libX11, steam, protontricks
, winePrefix
}:
let
  version = "2026.11.0";
  executable = "s4mp-online-launcher-${version}.exe";
  # Early access requires a licensed download; never put account cookies or the
  # proprietary executable in Git. Import it once, then Nix retains the payload.
  launcher = requireFile {
    name = executable;
    sha256 = "448f5abb40eb05afda5c2e76d793d79d3dbdd6641d95d93718eba58c0e6fead0";
    message = ''
      Download S4MP Early Access ${version} from https://sims-multiplayer.com/.
      Import the original Windows executable with:
        nix-store --add-fixed sha256 /path/to/${executable}
    '';
  };
  bridge = pkgsCross.mingwW64.stdenv.mkDerivation {
    pname = "s4mp-steam-bridge";
    inherit version;
    dontUnpack = true;
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      ${pkgsCross.mingwW64.stdenv.cc.bintools}/bin/${pkgsCross.mingwW64.stdenv.cc.targetPrefix}windres \
        ${./s4mp/steam-start.rc} -O coff -o version.o
      $CC -Os -municode -mwindows -nostdlib -Wl,--entry,entry -s \
        ${./s4mp/steam-start.c} version.o -lkernel32 -luser32 -lshell32 -o S4MPgo_.exe
      runHook postBuild
    '';
    installPhase = ''
      install -Dm755 S4MPgo_.exe "$out/bin/S4MPgo_.exe"
    '';
  };
  desktop = makeDesktopItem {
    name = "s4mp-early-access";
    desktopName = "S4MP Early Access (${version})";
    comment = "Sims 4 Multiplayer using the existing Steam Proton prefix";
    exec = "s4mp-early-access";
    icon = "applications-games";
    categories = [ "Game" ];
    startupNotify = true;
  };
  patchPython = python3.withPackages (ps: [ ps.brotli ]);
in
stdenvNoCC.mkDerivation {
  pname = "s4mp";
  inherit version;
  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    mkdir -p "$out/libexec/s4mp" "$out/bin"
    ${patchPython}/bin/python3 ${./s4mp/patch-launcher.py} \
      ${launcher} "$out/libexec/s4mp/${executable}"
    install -m755 ${bridge}/bin/S4MPgo_.exe "$out/libexec/s4mp/S4MPgo_.exe"
    install -m644 ${./s4mp/steam-launch-runtime.py} "$out/libexec/s4mp/steam-launch-runtime.py"
    install -m644 ${./s4mp/cursor-fallback.py} "$out/libexec/s4mp/cursor-fallback.py"
    makeWrapper ${python3}/bin/python3 "$out/bin/s4mp-early-access" \
      --add-flags "$out/libexec/s4mp/steam-launch-runtime.py" \
      --set S4MP_PACKAGE_DIR "$out/libexec/s4mp" \
      --set S4MP_WINEPREFIX ${lib.escapeShellArg winePrefix} \
      --set S4MP_STEAM ${steam}/bin/steam \
      --set S4MP_PROTONTRICKS_LAUNCH ${protontricks}/bin/protontricks-launch \
      --set S4MP_LIBX11 ${libX11}/lib/libX11.so.6
    cp -r ${desktop}/share "$out/share"
  '';
  meta = {
    description = "S4MP early-access launcher with the Sims 4 Steam launch bridge";
    homepage = "https://sims-multiplayer.com/";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "s4mp-early-access";
  };
}
