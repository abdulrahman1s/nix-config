{ pkgs, username, config, ... }:

let
  homeDir = config.users.users.${username}.home;
in
{
  # Symlink ghostty's shipped systemd user service & D-Bus service
  # (same approach as home-manager)
  system.activationScripts.ghosttySystemd = {
    deps = [ "users" ];
    text = ''
      mkdir -p "${homeDir}/.config/systemd/user/graphical-session.target.wants"
      chown -R ${username}:users "${homeDir}/.config/systemd/user"
      ln -sfn "${pkgs.ghostty}/share/systemd/user/app-com.mitchellh.ghostty.service" \
        "${homeDir}/.config/systemd/user/app-com.mitchellh.ghostty.service"
      ln -sfn "../app-com.mitchellh.ghostty.service" \
        "${homeDir}/.config/systemd/user/graphical-session.target.wants/app-com.mitchellh.ghostty.service"
      chown -Rh ${username}:users "${homeDir}/.config/systemd/user"
    '';
  };

  services.dbus.packages = [ pkgs.ghostty ];
}
