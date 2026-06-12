# Isolated-user wrapper: builds the inner sandbox via mkSandboxed AND wraps
# it to run as a dedicated system user via passwordless sudo. The host user
# keeps their session, but the app's filesystem and process tree live under
# a separate uid that can be audited and constrained independently.
#
# Why a system user instead of just bwrap? Three reasons:
#   1. /proc visibility. bwrap can't hide the host user's processes from
#      a sandboxed binary running as the same uid (kernel cred check).
#      A different uid + hidepid mount on /proc cleanly partitions.
#   2. Resource accounting. systemd-run --user --scope binds CPU/Memory
#      limits to the invoking uid; running as a different uid gives the
#      sandboxed app its own cgroup branch independent of the host user's.
#   3. Filesystem audit. Crashes, leaked files, profile poisoning are all
#      owned by the private uid and clearly attributable.
#
# API: accepts the union of mkSandboxed's args (passed through verbatim to
# build the inner sandbox) and the private-user-specific args below. Single
# declaration of `homeBinds` flows into both the bwrap mounts (via the inner
# sandbox) and the ACL grants (read back from `passthru.homeBinds`).
#
# Private-user-specific args:
#   runAsUser          - dedicated system user to sudo to (e.g. "brave-private").
#   hostUser           - real user (for sudoers `users` and ACL grants).
#   hostHome           - default "/home/${hostUser}".
#   runAsHome          - default "/var/lib/${runAsUser}".
#   sudoArgvValidator  - shell snippet validating "$@" before the final exec.
#                        The wrapper provides `reject_arg "$1"` and an exported
#                        `RUN_AS_HOME` shell var; the snippet must `exit 64`
#                        (via reject_arg) on any unsupported argument. The
#                        wrapper appends `exec ${innerSandbox}/bin/${name} "$@"`
#                        after the validator runs.
#   resourceLimits     - { cpu; mem; } or null. Applied via systemd-run --user
#                        --scope wrapping the sudo call (NOT the inner). The
#                        inner sandbox's own resourceLimits is forced to null
#                        so limits cover the whole sudo+bwrap process tree.
#   envPreserveList    - env vars threaded through sudo --preserve-env. Defaults
#                        cover Wayland + audio + GTK + cursor + SSL bundles.
#   extraGroups        - groups added to the private user (default: media groups
#                        for audio/input/video access).
#   extraDesktopReplacements - list of { from; to; } for substituteInPlace on
#                        .desktop files. Used for app-specific upstream paths
#                        that may leak into Exec/TryExec (e.g. Brave's nightly
#                        path baked into [Desktop Action ...] entries).
#
# Returns: { package, module } — `package` is the wrapped derivation,
# `module` is a NixOS module containing the system user, sudoers rule,
# and combined home-ACL + profile-dir activation script.
{ pkgs, mkSandboxed }:

let
  defaultEnvPreserveList = [
    "DISPLAY"
    "WAYLAND_DISPLAY"
    "XDG_RUNTIME_DIR"
    "DBUS_SESSION_BUS_ADDRESS"
    "PULSE_SERVER"
    "XCURSOR_THEME"
    "XCURSOR_SIZE"
    "XDG_CURRENT_DESKTOP"
    "DESKTOP_SESSION"
    "NIXOS_OZONE_WL"
    "XDG_SESSION_TYPE"
    "GDK_BACKEND"
    "QT_QPA_PLATFORM"
    "MOZ_ENABLE_WAYLAND"
    "SSL_CERT_FILE"
    "NIX_SSL_CERT_FILE"
  ];

  defaultExtraGroups = [
    "audio"
    "input"
    "render"
    "video"
  ];

  defaultRwPerms = "rwX";
  defaultRoPerms = "rX";

  # Parents of a $HOME-relative suffix.
  # "/.config/A/B"  → [ "" "/.config" "/.config/A" ]
  # "/Downloads"    → [ "" ]
  # ""              → [ ]
  parentsOf = suffix:
    let
      parts = builtins.filter (s: s != "") (pkgs.lib.splitString "/" suffix);
      mkPrefix = i:
        if i == 0 then ""
        else "/" + pkgs.lib.concatStringsSep "/" (pkgs.lib.take i parts);
    in
    builtins.genList mkPrefix (builtins.length parts);
in
{ runAsUser
, hostUser
, hostHome ? "/home/${hostUser}"
, runAsHome ? "/var/lib/${runAsUser}"
, sudoArgvValidator ? ''reject_arg "$1"''
, resourceLimits ? null
, envPreserveList ? defaultEnvPreserveList
, extraGroups ? defaultExtraGroups
, extraDesktopReplacements ? [ ]
, ...
}@args:

let
  # Split args: private-user-local vs. passthrough to mkSandboxed.
  innerArgs = builtins.removeAttrs args [
    "runAsUser"
    "hostUser"
    "hostHome"
    "runAsHome"
    "sudoArgvValidator"
    "resourceLimits"
    "envPreserveList"
    "extraGroups"
    "extraDesktopReplacements"
  ];

  # Build the inner sandbox. Resource limits are applied at the OUTER private
  # launcher's systemd-run scope so they cover sudo+bwrap+app, not just app —
  # forcing null here prevents double-scoping.
  innerSandbox = mkSandboxed (innerArgs // { resourceLimits = null; });

  name = innerArgs.name or innerArgs.package.pname;
  configDir = innerArgs.configDir or name;
  extraBinNames = innerArgs.extraBinNames or [ ];

  envPreserveStr = builtins.concatStringsSep "," envPreserveList;

  sudoTarget = pkgs.writeShellScript "${name}-private-sudo-target" ''
    set -euo pipefail

    RUN_AS_HOME=${pkgs.lib.escapeShellArg runAsHome}

    reject_arg() {
      echo "${name}: refusing unsupported argument for private profile: $1" >&2
      exit 64
    }

    ${sudoArgvValidator}

    exec ${innerSandbox}/bin/${name} "$@"
  '';

  sudoInvocation = ''
    /run/wrappers/bin/sudo \
      --user ${runAsUser} \
      --set-home \
      --preserve-env=${envPreserveStr} \
      -- \
      ${sudoTarget} "$@"
  '';

  privateLauncher = pkgs.writeShellScript "${name}-private-launcher" ''
    set -euo pipefail

    if [ -z "''${XDG_RUNTIME_DIR:-}" ]; then
      echo "${name}: XDG_RUNTIME_DIR is not set; cannot expose the Wayland session to ${runAsUser}" >&2
      exit 1
    fi

    runtime_dir=$XDG_RUNTIME_DIR
    if [ ! -d "$runtime_dir" ]; then
      echo "${name}: XDG_RUNTIME_DIR does not exist: $runtime_dir" >&2
      exit 1
    fi
    pulse_socket=$runtime_dir/pulse/native

    # Grant rwx/rw on a runtime socket or our own scratch dir.
    grant_socket() {
      local path=$1
      local mode=''${2:-required}
      [ -e "$path" ] || return 0

      local perms=rwx
      [ -d "$path" ] || perms=rw-

      if ! ${pkgs.acl}/bin/setfacl -m "u:${runAsUser}:$perms" "$path"; then
        if [ "$mode" = optional ]; then
          echo "${name}: warning: could not grant ${runAsUser} access to $path; continuing" >&2
          return 0
        fi
        echo "${name}: failed to grant ${runAsUser} access to $path" >&2
        exit 1
      fi
    }

    # rwx on the runtime dir itself. The private uid needs WRITE here because
    # nixpak's launcher binds its own proxy sockets directly under
    # $XDG_RUNTIME_DIR (nixpak-bus-<id>, nixpak-wayland-<id> — see
    # nixpak/modules/launch.nix and launcher/main.go). A traversal-only ACL
    # is not enough; bind(2) on a new socket needs write on the containing dir.
    grant_socket "$runtime_dir"

    ${pkgs.coreutils}/bin/mkdir -p "$runtime_dir/${name}-singleton-tmp" "$runtime_dir/.flatpak"
    grant_socket "$runtime_dir/${name}-singleton-tmp"
    grant_socket "$runtime_dir/.flatpak"

    for socket in "$runtime_dir"/wayland-* "$runtime_dir"/pipewire-* "$runtime_dir"/bus; do
      grant_socket "$socket"
    done

    for socket in "$runtime_dir"/pulse "$pulse_socket" "$runtime_dir"/gvfsd; do
      grant_socket "$socket" optional
    done

    if [ -e "$pulse_socket" ]; then
      export PULSE_SERVER=unix:$pulse_socket
    fi

    ${
      if resourceLimits == null then
        ''exec ${sudoInvocation}''
      else
        ''
          exec ${pkgs.systemd}/bin/systemd-run --user --scope --collect --same-dir \
            --unit="${name}-private-sandbox-$$" \
            -p CPUQuota=${resourceLimits.cpu} \
            -p MemoryMax=${resourceLimits.mem} \
            --description="${name} (Private Restricted)" \
            -- \
            ${sudoInvocation}
        ''
    }
  '';

  # Caller-provided `to` strings are literal (may contain shell expansions
  # like "$out/bin/${name}" — the runCommand body is the shell context).
  # The framework supplies the base inner→outer rewrite automatically.
  desktopReplacementFlags =
    let
      base = [
        { from = "${innerSandbox}/bin/${name}"; to = "$out/bin/${name}"; }
      ];
      flag = r: ''--replace-fail "${r.from}" "${r.to}"'';
    in
    builtins.concatStringsSep " \\\n              "
      (map flag (base ++ extraDesktopReplacements));

  package = pkgs.runCommand "${name}-private-sandboxed"
    {
      passthru.privateSudoCommand = "${sudoTarget}";
    }
    ''
      mkdir -p $out/bin
      ln -s ${privateLauncher} $out/bin/${name}

      for extraBin in ${toString extraBinNames}; do
        ln -s $out/bin/${name} $out/bin/$extraBin
      done

      if [ -d "${innerSandbox}/share" ]; then
        cp -a ${innerSandbox}/share $out/share
        if [ -d "$out/share/applications" ]; then
          find "$out/share/applications" -type f -name '*.desktop' -print0 | while IFS= read -r -d "" desktop; do
            substituteInPlace "$desktop" \
              ${desktopReplacementFlags}
          done
        fi
      fi
    '';

  # Derive ACL grants + traversal dirs from the inner sandbox's effective
  # homeBinds (caller's declarations merged with active preset contributions).
  effectiveHomeBinds = innerSandbox.homeBinds;

  homeTraversalDirs = pkgs.lib.unique (
    pkgs.lib.concatMap parentsOf (
      map (e: e.suffix) (effectiveHomeBinds.rw ++ effectiveHomeBinds.ro)
    )
  );

  # Parent dirs of the app's profile path (relative to runAsHome). For
  # configDir = "BraveSoftware/Brave-Browser" we need to `install -d` both
  # `.config` and `.config/BraveSoftware` so the inner sandbox's first-run
  # mkdir of the leaf profile dir doesn't race with non-existent parents.
  configDirParents =
    builtins.filter (p: p != "") (parentsOf "/.config/${configDir}");

  homeAclScript =
    let
      grantTraversal = suffix: ''setfacl_x "${hostHome}${suffix}"'';
      grantRecursive = defaultPerms: entry:
        ''setfacl_rec "${hostHome}${entry.suffix}" "${entry.perms or defaultPerms}"'';
      ensureProfileParent = p:
        ''install -d -m 0700 -o ${runAsUser} -g ${runAsUser} ${runAsHome}${p}'';
    in
    ''
      setfacl_x() {
        local path=$1
        [ -e "$path" ] || return 0
        ${pkgs.acl}/bin/setfacl -m "u:${runAsUser}:X" "$path" 2>/dev/null || true
      }
      setfacl_rec() {
        local path=$1
        local perms=$2
        [ -e "$path" ] || return 0
        ${pkgs.acl}/bin/setfacl -R -m "u:${runAsUser}:$perms" "$path" 2>/dev/null || true
        if [ -d "$path" ]; then
          ${pkgs.acl}/bin/setfacl -d -m "u:${runAsUser}:$perms" "$path" 2>/dev/null || true
        fi
      }

      # Materialise the private user's home + profile-dir parents. createHome
      # on the user only fires on creation; this is the per-rebuild reconcile
      # against drift (manual edits, prior failures).
      install -d -m 0700 -o ${runAsUser} -g ${runAsUser} ${runAsHome}
      ${pkgs.lib.concatMapStringsSep "\n" ensureProfileParent configDirParents}
      install -d -m 0700 -o ${runAsUser} -g ${runAsUser} ${runAsHome}/.config/${configDir}
      chown -R ${runAsUser}:${runAsUser} ${runAsHome}
      chmod 0700 ${runAsHome}

      # Traversal X-grants on the host-home ancestors of every bound leaf.
      ${pkgs.lib.concatMapStringsSep "\n" grantTraversal homeTraversalDirs}

      # Recursive rw/ro grants on the bound leaves themselves.
      ${pkgs.lib.concatMapStringsSep "\n" (grantRecursive defaultRwPerms) effectiveHomeBinds.rw}
      ${pkgs.lib.concatMapStringsSep "\n" (grantRecursive defaultRoPerms) effectiveHomeBinds.ro}
    '';

  module = {
    users.groups.${runAsUser} = { };

    users.users.${runAsUser} = {
      isSystemUser = true;
      group = runAsUser;
      home = runAsHome;
      createHome = true;
      homeMode = "700";
      inherit extraGroups;
    };

    security.sudo.extraRules = [
      {
        users = [ hostUser ];
        runAs = runAsUser;
        commands = [
          {
            command = "${sudoTarget}";
            options = [
              "NOPASSWD"
              "SETENV"
            ];
          }
        ];
      }
    ];

    system.activationScripts."${name}-private-home-acls" = {
      deps = [ "users" ];
      text = homeAclScript;
    };
  };
in
{
  inherit package module;
}
