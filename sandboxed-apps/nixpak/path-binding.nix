# Path-binding launcher: outermost wrapper that narrows the sandbox's
# rw bind to the host paths resolved from argv.
#
# Contract:
#   - Walks argv and collects EVERY arg that resolves to an existing
#     path (after file:// stripping and ~ expansion). Flag tokens like
#     `--foo` don't resolve and are passed through unchanged.
#   - In "dir" mode: each path's parent dir (for files) or the path
#     itself (for dirs) is rw-bound. Duplicate parents are deduplicated.
#     Refuses /, $HOME, and ancestors of $HOME so a stray `..` or `~`
#     doesn't expose the whole tree.
#   - In "file" mode: each FILE is rw-bound individually; the parent
#     dir stays hidden. Refuses dir args outright. With no resolving
#     candidate, binds /dev/null (no-op) and lands cwd at /.
#   - At most `maxPathSlots` paths bind per launch; overflow errors
#     out with a hint to pass a containing dir.
#   - Each candidate is exported as SANDBOX_PATH_<i> for sloth.envOr
#     to consume at bwrap spawn. mkSandboxed blanks all slots inside
#     the sandbox so the bound paths don't leak into app env.
#   - Tolerates RFC 8089 file:// variants: file:///path,
#     file://localhost/path, file:/path. Other-host forms
#     (file://host/path) are skipped (treated as unresolvable).
#   - Percent-decoding is pure bash and preserves literal `%` in
#     filenames when the URL is malformed.
#
# Exposed at this level so it can be unit-tested with a stub `innerEntry`,
# since `mkSandboxed` doesn't otherwise let you swap out what bwrap exec's.
# See `test-pathbinding.nix` for the test harness.
{ pkgs }:

let
  # Max distinct paths a single launch can rw-bind. nixpak's bind list is
  # baked at eval time, so we declare a fixed array of slots and the
  # launcher exports as many SANDBOX_PATH_<n> env vars as it has candidates.
  # Unused slots default to /dev/null via sloth.envOr. 16 is plenty for
  # realistic multi-file UIs (mpv playlists, file managers); apps that
  # exceed it get told to pass a containing directory.
  maxPathSlots = 16;

  mkPathBindingLauncher = { name, pathBinding, innerEntry }:
    assert pkgs.lib.assertMsg
      (pathBinding == "dir" || pathBinding == "file")
      "mkPathBindingLauncher (${name}): pathBinding must be \"dir\" or \"file\" (got: ${builtins.toJSON pathBinding})";
    pkgs.writeShellScript "${name}-path-binding" ''
      set -euo pipefail
      shopt -s inherit_errexit  # propagate command-substitution failures

      mode=${pathBinding}
      max_slots=${toString maxPathSlots}

      # Pure-bash percent decoder. `%XX` (XX = 2 hex digits) decodes to the
      # byte 0xXX; a stray `%` (not followed by 2 hex digits) is preserved
      # literally so a malformed file:// URL or a filename containing a
      # bare `%` doesn't trip printf's `\x` error onto stderr.
      url_decode() {
        local s=$1 out="" i=0 c hex
        while [ "$i" -lt "''${#s}" ]; do
          c=''${s:i:1}
          if [ "$c" = "%" ] && [ $((i + 3)) -le ''${#s} ]; then
            hex=''${s:i+1:2}
            case "$hex" in
              [0-9a-fA-F][0-9a-fA-F])
                printf -v c '\x'"$hex"
                out+=$c
                i=$((i + 3))
                continue
                ;;
            esac
          fi
          out+=$c
          i=$((i + 1))
        done
        printf '%s' "$out"
      }

      # Normalize a single arg: strip file:// scheme + percent-decode,
      # ~ expansion, make absolute. Tolerates RFC 8089 variants:
      # file:///path, file://localhost/path, file:/path. Other-host
      # forms (file://host/path) are skipped. Sets `normalized` to the
      # resulting absolute path if it exists on disk, "" otherwise.
      normalize_path_arg() {
        local arg=$1
        case "$arg" in
          "file://localhost/"*) arg=/''${arg#file://localhost/} ;;
          "file:///"*)          arg=/''${arg#file:///} ;;
          "file://"*)           normalized=; return ;;  # other-host
          "file:/"*)            arg=/''${arg#file:/} ;;
          "file:"*)             normalized=; return ;;  # malformed
        esac
        if [[ $arg == *%* ]]; then
          arg=$(url_decode "$arg")
        fi
        case "$arg" in
          "~")    arg=''${HOME:-/} ;;
          "~/"*)  arg=''${HOME:-/}/''${arg#"~/"} ;;
        esac
        case "$arg" in
          /*) ;;
          *)  arg=''${PWD:-/}/$arg ;;
        esac
        if [ -e "$arg" ]; then
          normalized=$arg
        elif [ -L "$arg" ]; then
          echo "${name}: skipping '$1' — broken symlink (dangling or looping)" >&2
          normalized=
        else
          normalized=
        fi
      }

      # Walk argv, collect every resolving path. Flag tokens like `--foo`
      # don't resolve and are skipped (passed through verbatim). Empty
      # args are skipped too — silently widening on an empty arg would
      # be surprising. Multi-path apps (mpv playlists, file managers
      # bulk-opening) get every path bound, deduplicated in dir mode.
      candidates=()       # bind targets (deduped)
      canon_args=()       # canonical paths for argv rewriting
      arg_indices=()      # original argv indices for rewriting
      idx=0
      for arg in "$@"; do
        if [ -n "$arg" ]; then
          normalize_path_arg "$arg"
          if [ -n "$normalized" ]; then
            if ! canon=$(${pkgs.coreutils}/bin/readlink -f -- "$normalized" 2>/dev/null); then
              echo "${name}: skipping '$arg' — couldn't canonicalize (symlink loop?)" >&2
              idx=$((idx + 1))
              continue
            fi
            if [ -d "$canon" ]; then
              if [ "$mode" = "file" ]; then
                echo "${name}: file mode rejects directory argument: $canon" >&2
                exit 1
              fi
              bind=$canon
            else
              if [ "$mode" = "file" ]; then
                bind=$canon
              else
                parent=''${canon%/*}
                bind=''${parent:-/}
              fi
            fi
            # Dedup (mostly meaningful in dir mode — siblings collapse
            # to one parent bind).
            already=0
            for c in "''${candidates[@]+"''${candidates[@]}"}"; do
              if [ "$c" = "$bind" ]; then already=1; break; fi
            done
            if [ "$already" = 0 ]; then
              candidates+=("$bind")
            fi
            canon_args+=("$canon")
            arg_indices+=("$idx")
          fi
        fi
        idx=$((idx + 1))
      done

      # cwd_target: file-mode no-candidate fallback may pin it; otherwise
      # computed below from the first candidate.
      cwd_target=

      # Fallback when no arg resolved.
      if [ "''${#candidates[@]}" -eq 0 ]; then
        if [ "$#" -gt 0 ]; then
          echo "${name}: no argument resolved to an existing path; falling back" >&2
        fi
        if [ "$mode" = "file" ]; then
          # File mode: bind /dev/null as a no-op so the required rw-bind
          # on SANDBOX_PATH_0 doesn't widen visibility. Pin cwd=/ so the
          # inner cwd lands at / instead of in /dev (which would be weird
          # and pollute `pwd` output in app-spawned shells).
          candidates+=("/dev/null")
          cwd_target=/
        else
          # Dir mode: bind $PWD. Falls through to the HOME/'/' refusals
          # below — if the user happens to be in $HOME, we refuse rather
          # than expose the whole tree.
          candidates+=("$(${pkgs.coreutils}/bin/readlink -f -- "''${PWD:-/}")")
        fi
      fi

      # Refuse to bind / (filesystem root) or an empty path. Empty is
      # unreachable by construction but cheap defense in depth.
      for sp in "''${candidates[@]}"; do
        case "$sp" in
          "" | "/")
            echo "${name}: refusing to bind '$sp' (empty or filesystem root)" >&2
            exit 1
            ;;
        esac
      done${pkgs.lib.optionalString (pathBinding == "dir") ''

      # Dir mode only: refuse if any bind would cover $HOME at any
      # ancestor level. Catches `~`, files directly under $HOME, parents
      # reachable via `..` chains, and running from those dirs with no
      # arg. The quoted patterns force $sp to be matched as a literal
      # prefix even if it contains glob metacharacters like `[`. HOME
      # defaults to "/" so an unset $HOME doesn't trip set -u.
      home_canon=$(${pkgs.coreutils}/bin/readlink -f -- "''${HOME:-/}")
      for sp in "''${candidates[@]}"; do
        case "$home_canon" in
          "$sp" | "$sp"/*)
            echo "${name}: refusing to bind '$sp' — would cover \$HOME ($home_canon); pass a specific subdirectory of \$HOME instead" >&2
            exit 1
            ;;
        esac
      done''}

      # Overflow: nixpak's bind list is fixed-size, so we can't accept
      # arbitrary path counts. Tell the user to pass a containing dir.
      if [ "''${#candidates[@]}" -gt "$max_slots" ]; then
        echo "${name}: too many path arguments (''${#candidates[@]} > $max_slots); pass a containing directory instead" >&2
        exit 1
      fi

      # Show the user which host paths the sandbox is about to rw-bind.
      echo "${name}: binding ''${#candidates[@]} path(s) [$mode]:" >&2
      for sp in "''${candidates[@]}"; do
        echo "  $sp" >&2
      done

      # Rewrite argv slots with canonical paths so the app sees paths that
      # exist inside the sandbox after symlink canonicalization. Flags and
      # sidecar args stay in their original positions.
      if [ "''${#canon_args[@]}" -gt 0 ]; then
        args=("$@")
        for ((j=0; j<''${#canon_args[@]}; j++)); do
          args[arg_indices[j]]=''${canon_args[j]}
        done
        set -- "''${args[@]}"
      fi

      # Export SANDBOX_PATH_<i> for each candidate. Unused slots stay
      # unset; nixpak's sloth.envOr defaults them to /dev/null at bwrap
      # spawn, so the bind list is the same shape regardless of count.
      for ((j=0; j<''${#candidates[@]}; j++)); do
        export "SANDBOX_PATH_$j=''${candidates[j]}"
      done

      # cwd_target: explicit override (file-mode no-candidate) already
      # set. Otherwise pick the first candidate's dir — apps with file
      # args land in the file's directory; dir-arg apps land inside the
      # dir. bwrap synthesizes parent dirs for bound files so cd works
      # in file mode too.
      if [ -z "$cwd_target" ]; then
        first=''${candidates[0]}
        if [ -d "$first" ]; then
          cwd_target=$first
        else
          cwd_parent=''${first%/*}
          cwd_target=''${cwd_parent:-/}
        fi
      fi
      cd -- "$cwd_target"
      exec ${innerEntry} "$@"
    '';
in
{
  inherit maxPathSlots mkPathBindingLauncher;
}
