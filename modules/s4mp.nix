# S4MP needs a licensed download imported into the store by hand, so CI cannot
# build it. Keeping it in its own module lets flake.nix's CI variant disable it.
{ config, pkgs, username, ... }:
let
  # Native exception: S4MP shares the installed game's Proton prefix and hands
  # Start Game to host Steam. Another sandbox would split that launch context.
  s4mp = pkgs.callPackage ../local-packages/s4mp.nix {
    steam = config.programs.steam.package;
    protontricks = config.programs.steam.protontricks.package;
    winePrefix = "/mnt/990Pro/SteamLibrary/steamapps/compatdata/1222670/pfx";
  };
in
{
  users.users.${username}.packages = [ s4mp ];

  # Multiplayer hosting over LAN or VPN.
  networking.firewall.allowedTCPPorts = [ 7654 ];

  # The old user desktop entry names ~/.local/bin directly. Keep it working,
  # backing up the known manual launcher instead of overwriting user scripts.
  system.userActivationScripts.s4mp-launcher.text = ''
    launcher="$HOME/.local/bin/s4mp-early-access"
    target="${s4mp}/bin/s4mp-early-access"
    ${pkgs.coreutils}/bin/install -d -m 0755 "$HOME/.local/bin"
    if [ -L "$launcher" ]; then
      case "$(${pkgs.coreutils}/bin/readlink "$launcher")" in
        /nix/store/*-s4mp-*/bin/s4mp-early-access)
          ${pkgs.coreutils}/bin/ln -sfn "$target" "$launcher" ;;
        *) echo "S4MP: preserving existing symlink $launcher" >&2 ;;
      esac
    elif [ -f "$launcher" ]; then
      hash=$(${pkgs.coreutils}/bin/sha256sum "$launcher")
      if [ "''${hash%% *}" = "d32be3070c12f97b75fb3f9b49072916ecbf412ef5e1bacd8bcea15e3ac7b56c" ] \
          && [ ! -e "$launcher.before-nixos" ] && [ ! -L "$launcher.before-nixos" ]; then
        ${pkgs.coreutils}/bin/mv "$launcher" "$launcher.before-nixos"
        ${pkgs.coreutils}/bin/ln -s "$target" "$launcher"
      else
        echo "S4MP: preserving existing launcher $launcher" >&2
      fi
    elif [ ! -e "$launcher" ]; then
      ${pkgs.coreutils}/bin/ln -s "$target" "$launcher"
    else
      echo "S4MP: preserving conflicting path $launcher" >&2
    fi
  '';
}
