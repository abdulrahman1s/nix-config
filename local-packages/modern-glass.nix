{ lib, mpvScripts, fetchzip, coreutils, ffmpeg }:

mpvScripts.buildLua (finalAttrs: {
  pname = "modern-glass";
  version = "0-unstable-2026-10-14";

  src = fetchzip {
    url = "https://codeload.github.com/Demetter/ModernGlass/tar.gz/2963b9e11cca98a726b1b2912f52d157a709d759";
    extension = "tar.gz";
    hash = "sha256-H2YYe6mvflPkTnonyZJ/eB6+geBkyv/7eiRMH8JfBFk=";
  };

  scriptPath = "modernz.lua";
  extraScriptsToCopy = [ "thumbz.lua" ];
  postInstall = ''
    install -Dm644 fonts/Inter-Medium.ttf "$out/share/fonts/truetype/Inter-Medium.ttf"
    install -Dm644 fonts/Inter-SemiBold.ttf "$out/share/fonts/truetype/Inter-SemiBold.ttf"
  '';

  passthru = {
    extraScriptsToLoad = [ "thumbz.lua" ];
    fontDirectories = [ "${finalAttrs.finalPackage}/share/fonts" ];
    extraWrapperArgs = [
      "--prefix" "PATH" ":" (lib.makeBinPath [ coreutils ffmpeg ])
      # ModernGlass adjusts subtitle placement; restoring sub-pos conflicts with it.
      "--add-flags" "--osc=no --video-sync=display-resample --watch-later-options-remove=sub-pos"
    ];
  };

  meta = {
    description = "Glass-style mpv controls with menus and thumbnail previews";
    homepage = "https://github.com/Demetter/ModernGlass";
    license = with lib.licenses; [ lgpl21Plus ofl mit asl20 ];
    platforms = lib.platforms.all;
  };
})
