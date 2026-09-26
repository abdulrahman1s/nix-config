{ config, lib, pkgs, ... }:

let
  cfg = config.personal-ai;
  sorter = pkgs.writeShellApplication {
    name = "ai-sort-files";
    runtimeInputs = [ pkgs.python3 pkgs.zenity ];
    text = ''
      export PERSONAL_AI_LOCAL_URL=${lib.escapeShellArg cfg.privacy.localEndpoint}
      export PERSONAL_AI_ZENITY=${lib.getExe pkgs.zenity}
      exec ${lib.getExe pkgs.python3} ${./file-sorter.py} "$@"
    '';
  };
  nautilusExtension = pkgs.writeTextFile {
    name = "personal-ai-nautilus-extension";
    destination = "/share/nautilus-python/extensions/personal-ai-sort.py";
    text = lib.replaceStrings
      [ "@SORTER_EXECUTABLE@" ]
      [ (lib.getExe sorter) ]
      (builtins.readFile ./nautilus-sort.py);
  };
in
{
  config = lib.mkIf cfg.enable {
    # Nautilus loads Python menu providers from XDG_DATA_DIRS, including the
    # system profile. The extension itself stays in the Nix store.
    environment.systemPackages = [ pkgs.nautilus-python nautilusExtension sorter ];
  };
}
