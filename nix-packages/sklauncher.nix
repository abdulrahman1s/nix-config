{ lib, appimageTools, fetchurl, sklauncher }:

let
  pname = "sklauncher";
  version = sklauncher.version;
  src = fetchurl {
    url = "https://github.com/sklauncher/binaries/releases/download/v${version}/SKlauncher-${version}-x86_64.AppImage";
    hash = sklauncher.hash;
  };
  contents = appimageTools.extract {
    inherit pname version src;
    postExtract = ''
      # The upstream AppRun silently adds --no-sandbox when its nested
      # user-namespace probe fails inside NixPak. Keep Electron sandboxing on.
      substituteInPlace "$out/AppRun" \
        --replace-fail 'NO_SANDBOX=(--no-sandbox)' 'NO_SANDBOX=()'
    '';
  };
in
appimageTools.wrapAppImage {
  inherit pname version src contents;
  meta = {
    description = "Minecraft launcher with instance and modpack management";
    homepage = "https://skmedix.pl";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = pname;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
