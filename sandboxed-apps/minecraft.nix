{ pkgs, inputs, utils, sandboxedXdgUtils, ... }:

let
  sklauncher = inputs.self.packages.${pkgs.system}.sklauncher;

  minecraft-pkg = pkgs.symlinkJoin {
    name = "minecraft";
    paths = [
      (
        pkgs.writeShellScriptBin "minecraft" ''
          exec ${sklauncher}/bin/sklauncher "$@"
        ''
      )
      (pkgs.makeDesktopItem {
        name = "minecraft";
        exec = "minecraft";
        icon = "applications-games";
        desktopName = "Minecraft";
        categories = [ "Game" ];
      })
    ];
  };

in
utils.mkSandboxed {
  package = minecraft-pkg;
  name = "minecraft";
  displayName = "Minecraft";
  wmClass = "pl.skmedix.sklauncher";
  configDir = "sklauncher";
  extraPackages = [ sandboxedXdgUtils ];
  presets = [
    "wayland"
    "gpu" # Required for OpenGL/Hardware acceleration
    "audio" # Game sound
    "network" # Login and game downloads
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
