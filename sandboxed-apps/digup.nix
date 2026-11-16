{ pkgs, utils, sandboxedXdgUtils, ... }:

let
  documentFolders = [ "Documents" "Pictures" "Downloads" "Books" "Inbox" ];
  configure = pkgs.writeText "digup-settings.py" ''
    import json
    import os
    from pathlib import Path
    import tempfile

    home = Path.home()
    folder = Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config") / "com.abdurrahim.DigUp"
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = folder / "settings.json"
    if path.is_symlink():
        raise RuntimeError(f"Refusing to replace symlink: {path}")
    original = path.read_bytes() if path.exists() else None
    previous = json.loads(original) if original is not None else {}
    if not isinstance(previous, dict):
        raise ValueError(f"Expected a settings object in {path}")

    documents = [str(home / name) for name in ${builtins.toJSON documentFolders}
                 if (home / name).is_dir()]
    defaults = {
        "folders": documents,
        "codeFolders": [str(home / "projects")] if (home / "projects").is_dir() else [],
        "setUp": True,
    }
    settings = defaults | previous
    # The sandbox exposes individual trees; the home root itself cannot be walked.
    selected = []
    for root in settings["folders"]:
        selected.extend(documents if Path(root) == home else [root])
    settings["folders"] = list(dict.fromkeys(selected))
    # The Niri rule clears GTK's tiled state so the compact panel can resize.
    settings["centerPanel"] = False
    # Updates are pinned and installed through Nix.
    settings["updateChecksOff"] = True

    if settings != previous:
        if original is not None:
            try:
                with (folder / "settings.json.before-nix-setup").open("xb") as backup:
                    os.chmod(backup.name, 0o600)
                    backup.write(original)
            except FileExistsError:
                pass
        with tempfile.NamedTemporaryFile(mode="w", dir=folder, delete=False) as temporary:
            temporary_path = Path(temporary.name)
            try:
                json.dump(settings, temporary, indent=2)
                temporary.write("\n")
                temporary.flush()
                os.replace(temporary_path, path)
            finally:
                temporary_path.unlink(missing_ok=True)
  '';
  unwrapped = pkgs.callPackage ../local-packages/digup.nix {
    xdg-utils = sandboxedXdgUtils;
  };
  package = pkgs.symlinkJoin {
    name = "digup-configured-${unwrapped.version}";
    paths = [ unwrapped ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram "$out/bin/digup-shell" \
        --run "${pkgs.python3}/bin/python3 ${configure}"
    '';
    inherit (unwrapped) meta;
  };
in
utils.mkSandboxed {
  inherit package;
  name = "digup";
  displayName = "DigUp";
  wmClass = "digup-shell";
  configDir = "com.abdurrahim.DigUp";
  # Network is needed for the first-run model download from Hugging Face.
  presets = [ "network" "wayland" "gpu" "audio" "portals" "systray" ];
  homeBinds = {
    rw = map (suffix: { inherit suffix; }) [
      "/.local/share/digup"
      "/.local/share/com.abdurrahim.DigUp"
    ];
    # Index only these trees; never expose the whole home or credentials.
    ro = map (name: { suffix = "/${name}"; }) (documentFolders ++ [ "projects" ]);
  };
  extraPerms = {
    # A second launch hands --toggle to the running Tauri shell over this name.
    dbus.policies."com.abdurrahim.DigUp.SingleInstance" = "own";
    bubblewrap.env = {
      MANGOHUD = "0";
      DISABLE_MANGOHUD = "1";
    };
  };
}
