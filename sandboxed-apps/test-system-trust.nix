# Regression test for the base sandbox's NixOS trust-store projection.
#
# /etc/ssl/certs/ca-certificates.crt is an absolute symlink into
# /etc/static/ssl/certs on NixOS. Both directories must be mounted, in that
# order, or GLib/GnuTLS clients such as WebKit see an empty trust database.
{ pkgs, nixpak }:

let
  helpers = import ./nixpak { inherit pkgs nixpak; };

  stubPackage = pkgs.writeShellApplication {
    name = "test-system-trust";
    text = "exit 0";
  };

  sandbox = helpers.mkSandboxed {
    package = stubPackage;
    name = "test-system-trust";
    exportDesktopFiles = false;
  };
in
pkgs.runCommand "sandbox-system-trust-test"
{
  nativeBuildInputs = [
    pkgs.coreutils
    pkgs.jq
  ];
}
  ''
    set -euo pipefail

    expected_paths='${builtins.toJSON helpers.systemTrustPaths}'
    test "$expected_paths" = '["/etc/ssl/certs","/etc/static/ssl/certs"]'

    launcher=$(${pkgs.coreutils}/bin/readlink -f ${sandbox}/bin/test-system-trust)
    args_file=$(${pkgs.gnused}/bin/sed -n \
      "s|^export BUBBLEWRAP_ARGS='\\(.*\\)'$|\\1|p" "$launcher")
    test -n "$args_file"

    ssl_index=$(jq 'to_entries
      | map(select(.value == "/etc/ssl/certs"))
      | first.key' "$args_file")
    static_index=$(jq 'to_entries
      | map(select(.value == "/etc/static/ssl/certs"))
      | first.key' "$args_file")

    # Each directory appears twice as a source/destination pair. The static
    # target must be mounted after the compatibility directory that links to it.
    test "$(jq '[.[] | select(. == "/etc/ssl/certs")] | length' "$args_file")" -eq 2
    test "$(jq '[.[] | select(. == "/etc/static/ssl/certs")] | length' "$args_file")" -eq 2
    test "$static_index" -gt "$ssl_index"

    touch "$out"
  ''
