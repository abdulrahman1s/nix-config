{ pkgs, utils, sandboxedXdgUtils, ... }:

let
  jarFile = pkgs.fetchurl {
    url = "https://skmedix.pl/binaries/skl/3.2.18/SKlauncher-3.2.18.jar";
    hash = "sha256-Jac+N3Ch2NFLzlPokg4uiTqsw8cV0Psi+HjvIJDQOGM=";
  };

  icon = pkgs.fetchurl {
    url = "https://minecraft.wiki/images/Bedrock_Edition_Google_Play_icon_1.png?daf7c?download"; # From https://minecraft.wiki/w/Logo
    hash = "sha256-PsKTTpqbPcwv+GDRvFh8Ass2HiqP3DL6tjglOZpINKA=";
  };

  minecraft-pkg = pkgs.symlinkJoin {
    name = "minecraft";
    paths = [
      (
        pkgs.writeShellScriptBin "minecraft" ''
          exec ${pkgs.steam-run}/bin/steam-run ${pkgs.javaPackages.compiler.temurin-bin.jre-25}/bin/java \
            --enable-native-access=ALL-UNNAMED \
            -Dawt.useSystemAAFontSettings=on \
            -jar "${jarFile}" "$@"
        ''
      )
      (pkgs.makeDesktopItem {
        name = "minecraft";
        exec = "minecraft";
        icon = "minecraft";
        desktopName = "Minecraft";
        categories = [ "Game" ];
      })
    ];
    postBuild = ''
      mkdir -p $out/share/icons/hicolor/256x256/apps
      ln -s ${icon} $out/share/icons/hicolor/256x256/apps/minecraft.png
    '';
  };

in
utils.mkSandboxed {
  package = minecraft-pkg;
  name = "minecraft";
  displayName = "Minecraft";
  wmClass = "java"; # JavaFX always reports WM_CLASS as 'java'
  extraPackages = [ sandboxedXdgUtils ];
  presets = [
    "wayland"
    "gpu" # Required for OpenGL/Hardware acceleration
    "audio" # Game sound
    "network" # Login and downloading updates
    "portals" # "Open directory" in launcher → xdg-desktop-portal
  ];

  extraPerms = { sloth, ... }: {
    bubblewrap.bind.rw = [
      (sloth.concat' sloth.homeDir "/.minecraft")
      (sloth.concat' sloth.homeDir "/.sklauncher")
      (sloth.concat' sloth.homeDir "/.openjfx") # JavaFX native lib cache
      (sloth.concat' sloth.homeDir "/minecraft-rtx")
      (sloth.concat' sloth.homeDir "/best-minecraft-ever")
    ];
  };
}
