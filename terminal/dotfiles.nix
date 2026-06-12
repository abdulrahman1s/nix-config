{ pkgs, username, ... }:

let
  themePath = "${pkgs.adw-gtk3}/share/themes/adw-gtk3-dark";

  linkAll = path: ''
    find "${path}" ! -type d -print0 | while IFS= read -r -d ''' src; do
      rel="''${src#${path}/}"
      dir="$(dirname "$rel")"
      [[ "$rel" == */assets/* || "$rel" == *.png || "$rel" == *.svg ]] || echo "  $rel → ~/.config/$rel"

      # Strip any ancestor that's a symlink (e.g. ~/.config/gtk-4.0/assets
      # left over from a prior theme path); mkdir -p would silently follow it
      # and ln -sfn would write inside its (read-only) target.
      if [ "$dir" != "." ]; then
        p="$HOME/.config"
        IFS=/ read -ra parts <<< "$dir"
        for part in "''${parts[@]}"; do
          p="$p/$part"
          [ -L "$p" ] && rm "$p"
        done
      fi

      mkdir -p "$HOME/.config/$dir"
      ln -sfn "$src" "$HOME/.config/$rel"
    done
  '';
in
{
  system.userActivationScripts.dotfiles.text = ''
    echo "── Symlinking dotfiles ──"
    # Theme files first so user-config files in config/ can override
    # any path they share (e.g. gtk-{3,4}.0/gtk.css).
    ${linkAll themePath}
    ${linkAll "/home/${username}/system-conf/config"}
    echo "── Done Symlinking files ──"
  '';
}
