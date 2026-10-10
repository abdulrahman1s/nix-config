{ lib, pkgs, username, ... }:

let
  themePath = "${pkgs.adw-gtk3}/share/themes/adw-gtk3-dark";
  configRoot = ../config;
  repoRoot = "/home/${username}/system-conf";
  repoConfigRoot = "${repoRoot}/config";
  rtkSkill = "${repoRoot}/.agents/skills/rtk/SKILL.md";

  relativeConfigPath = path:
    lib.removePrefix "${toString configRoot}/" (toString path);

  repoFiles = builtins.listToAttrs (
    map
      (path:
        let
          relativePath = relativeConfigPath path;
        in
        {
          name = relativePath;
          # Keep the existing live-edit behavior instead of linking to the
          # immutable flake source copied into the Nix store.
          value.source = "${repoConfigRoot}/${relativePath}";
        })
      (lib.filesystem.listFilesRecursive configRoot)
  );

  themeFiles = {
    "gtk-3.0".type = "directory";
    "gtk-3.0/assets" = {
      source = "${themePath}/gtk-3.0/assets";
      # The old activation script created this as a directory of symlinks.
      clobber = true;
    };
    "gtk-3.0/gtk-dark.css".source = "${themePath}/gtk-3.0/gtk-dark.css";
    "gtk-3.0/thumbnail.png".source = "${themePath}/gtk-3.0/thumbnail.png";

    "gtk-4.0".type = "directory";
    "gtk-4.0/assets" = {
      source = "${themePath}/gtk-4.0/assets";
      # The old activation script created this as a directory of symlinks.
      clobber = true;
    };
    "gtk-4.0/gtk-dark.css".source = "${themePath}/gtk-4.0/gtk-dark.css";
    "gtk-4.0/libadwaita-tweaks.css".source = "${themePath}/gtk-4.0/libadwaita-tweaks.css";
    "gtk-4.0/libadwaita.css".source = "${themePath}/gtk-4.0/libadwaita.css";
  };
in
{
  hjem.users.${username} = {
    clobberFiles = false;
    files = {
      ".codex/AGENTS.md" = {
        source = rtkSkill;
        clobber = true;
      };
      ".claude/CLAUDE.md" = {
        clobber = true;
        text = ''
          @${rtkSkill}
          # graphify
          - **graphify** (`~/.claude/skills/graphify/SKILL.md`) - any input to knowledge graph. Trigger: `/graphify`
          When the user types `/graphify`, invoke the Skill tool with `skill: "graphify"` before doing anything else.
        '';
      };
    };
    xdg.config.files = themeFiles // repoFiles // {
      "user-dirs.dirs".text = ''
        XDG_DOCUMENTS_DIR="$HOME/Documents"
        XDG_DOWNLOAD_DIR="$HOME/Downloads"
        XDG_PICTURES_DIR="$HOME/Pictures"
      '';
      "noctalia/plugins/linux-wallpaperengine-controller".type = "delete";
      "opencode/AGENTS.md".source = rtkSkill;
      # Migrate the existing mutable Zed settings into this repository.
      "zed/settings.json" = {
        source = "${repoConfigRoot}/zed/settings.json";
        clobber = true;
      };
    };
  };
}
