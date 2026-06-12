# Unit tests for the path-binding launcher. Run via:
#
#   nix flake check                       # runs all checks
#   nix build .#checks.x86_64-linux.pathbinding   # this check only
#
# We build the launcher with a stub `innerEntry` that prints every set
# SANDBOX_PATH_<i> + argv, so the tests exercise just the path-resolution
# / refusal logic — no bwrap, no user namespaces, fast.
{ pkgs, nixpak }:

let
  helpers = import ./nixpak { inherit pkgs nixpak; };

  # Prints exported slots only (unset slots stay silent so we can assert
  # on slot count too), then argv.
  stubInner = pkgs.writeShellScript "test-stub-inner" ''
    i=0
    while [ "$i" -lt 16 ]; do
      v=SANDBOX_PATH_$i
      if [ -n "''${!v+x}" ]; then
        printf 'SANDBOX_PATH_%d=%s\n' "$i" "''${!v}"
      fi
      i=$((i + 1))
    done
    for a in "$@"; do
      printf 'ARG=%s\n' "$a"
    done
  '';

  fileLauncher = helpers.mkPathBindingLauncher {
    name = "test-file";
    pathBinding = "file";
    innerEntry = "${stubInner}";
  };

  dirLauncher = helpers.mkPathBindingLauncher {
    name = "test-dir";
    pathBinding = "dir";
    innerEntry = "${stubInner}";
  };
in

pkgs.runCommand "pathbinding-tests"
  {
    nativeBuildInputs = [ pkgs.coreutils ];
  }
  ''
    set +e -uo pipefail  # stdenv enables -e; we WANT failures to capture into $?

    # The build sandbox doesn't have a real $HOME — point it at a fresh
    # temp dir so the HOME-ancestor refusals have something predictable
    # to canonicalize.
    export HOME=$(mktemp -d)
    scratch=$(mktemp -d)
    trap 'rm -rf "$HOME" "$scratch"' EXIT

    echo "data"   > "$scratch/file.txt"
    echo "data"   > "$scratch/sibling.txt"
    mkdir         "$scratch/subdir"
    echo "nested" > "$scratch/subdir/nested.txt"
    echo "home"   > "$HOME/home-file.txt"
    mkdir -p      "$HOME/safe-subdir"

    PASS=0
    FAIL=0

    assert_exit() {
      local name=$1 want=$2 got=$3
      if [ "$want" = "$got" ]; then
        printf 'PASS  %s\n' "$name"
        PASS=$((PASS + 1))
      else
        printf 'FAIL  %s (exit got=%s want=%s)\n' "$name" "$got" "$want"
        FAIL=$((FAIL + 1))
      fi
    }

    assert_contains() {
      local name=$1 needle=$2 haystack=$3
      case "$haystack" in
        *"$needle"*)
          printf 'PASS  %s\n' "$name"
          PASS=$((PASS + 1))
          ;;
        *)
          printf 'FAIL  %s\n' "$name"
          printf '      needle:   %s\n' "$needle"
          printf '      haystack: %s\n' "$haystack"
          FAIL=$((FAIL + 1))
          ;;
      esac
    }

    assert_not_contains() {
      local name=$1 needle=$2 haystack=$3
      case "$haystack" in
        *"$needle"*)
          printf 'FAIL  %s (unexpectedly contained: %s)\n' "$name" "$needle"
          FAIL=$((FAIL + 1))
          ;;
        *)
          printf 'PASS  %s\n' "$name"
          PASS=$((PASS + 1))
          ;;
      esac
    }

    # --- file mode ---

    stdout=$(${fileLauncher} "$scratch/file.txt" 2>&1); rc=$?
    assert_exit     "file/file: exits 0"                     0 "$rc"
    assert_contains "file/file: binds the file"              "SANDBOX_PATH_0=$scratch/file.txt" "$stdout"
    assert_contains "file/file: rewrites arg to canonical"   "ARG=$scratch/file.txt"            "$stdout"

    stdout=$(${fileLauncher} "$scratch" 2>&1); rc=$?
    assert_exit     "file/dir: refuses (exit 1)"             1 "$rc"
    assert_contains "file/dir: clear error"                  "file mode rejects directory argument" "$stdout"

    stdout=$(${fileLauncher} 2>&1); rc=$?
    assert_exit         "file/none: exits 0 (no-op /dev/null)" 0 "$rc"
    assert_contains     "file/none: binds /dev/null"           "SANDBOX_PATH_0=/dev/null" "$stdout"
    assert_not_contains "file/none: no fallback warning"       "no argument resolved" "$stdout"

    stdout=$(${fileLauncher} "~/home-file.txt" 2>&1); rc=$?
    assert_exit     "file/~path: exits 0"                    0 "$rc"
    assert_contains "file/~path: expands ~ and binds file"   "SANDBOX_PATH_0=$HOME/home-file.txt" "$stdout"

    stdout=$(${fileLauncher} "~" 2>&1); rc=$?
    assert_exit     "file/~ (dir): refuses"                  1 "$rc"

    stdout=$(${fileLauncher} "file://$scratch/file.txt" 2>&1); rc=$?
    assert_exit     "file/file:// : exits 0"                 0 "$rc"
    assert_contains "file/file:// : strips scheme + binds"   "SANDBOX_PATH_0=$scratch/file.txt" "$stdout"

    # RFC 8089 variant: file://localhost/path (KDE/Dolphin emits this).
    stdout=$(${fileLauncher} "file://localhost$scratch/file.txt" 2>&1); rc=$?
    assert_exit     "file/file://localhost: exits 0"         0 "$rc"
    assert_contains "file/file://localhost: strips + binds"  "SANDBOX_PATH_0=$scratch/file.txt" "$stdout"

    # RFC 8089 minimal: file:/path (single slash).
    stdout=$(${fileLauncher} "file:$scratch/file.txt" 2>&1); rc=$?
    assert_exit     "file/file:/ (single slash): exits 0"    0 "$rc"
    assert_contains "file/file:/: strips + binds"            "SANDBOX_PATH_0=$scratch/file.txt" "$stdout"

    # file://other-host/path — we have no way to reach it; should skip
    # and fall back (in file mode, to /dev/null with a warning).
    stdout=$(${fileLauncher} "file://other-host$scratch/file.txt" 2>&1); rc=$?
    assert_exit     "file/file://other-host: exits 0"        0 "$rc"
    assert_contains "file/file://other-host: skip+fallback"  "SANDBOX_PATH_0=/dev/null" "$stdout"
    assert_contains "file/file://other-host: warning"        "no argument resolved" "$stdout"

    stdout=$(cd "$scratch" && ${fileLauncher} "./file.txt" 2>&1); rc=$?
    assert_exit     "file/relative: exits 0"                 0 "$rc"
    assert_contains "file/relative: canonicalizes"           "SANDBOX_PATH_0=$scratch/file.txt" "$stdout"

    stdout=$(${fileLauncher} --some-flag "$scratch/file.txt" 2>&1); rc=$?
    assert_exit     "file/flag+path: exits 0"                0 "$rc"
    assert_contains "file/flag+path: picks the file"         "SANDBOX_PATH_0=$scratch/file.txt" "$stdout"
    assert_contains "file/flag+path: keeps flag in argv"     "ARG=--some-flag" "$stdout"

    stdout=$(${fileLauncher} "/" 2>&1); rc=$?
    assert_exit     "file//: refuses (dir)"                  1 "$rc"

    # Symlink to a file: should bind the symlink's target, not the symlink itself.
    ln -s "$scratch/file.txt" "$scratch/linked.txt"
    stdout=$(${fileLauncher} "$scratch/linked.txt" 2>&1); rc=$?
    assert_exit     "file/symlink: exits 0"                  0 "$rc"
    assert_contains "file/symlink: binds canonical target"   "SANDBOX_PATH_0=$scratch/file.txt" "$stdout"

    # Symlink loop: must warn + fall back (file mode → /dev/null) instead
    # of silently widening or crashing readlink under inherit_errexit.
    ln -s "$scratch/loop-b" "$scratch/loop-a"
    ln -s "$scratch/loop-a" "$scratch/loop-b"
    stdout=$(${fileLauncher} "$scratch/loop-a" 2>&1); rc=$?
    assert_exit     "file/symlink-loop: exits 0"             0 "$rc"
    assert_contains "file/symlink-loop: warns"               "broken symlink" "$stdout"
    assert_contains "file/symlink-loop: falls back"          "SANDBOX_PATH_0=/dev/null" "$stdout"

    # Literal % in a filename (not a URL). The bash percent-decoder must
    # preserve it as-is and not leak printf "\x" warnings to stderr.
    echo "data" > "$scratch/%literal.txt"
    stdout=$(${fileLauncher} "$scratch/%literal.txt" 2>&1); rc=$?
    assert_exit         "file/literal-%: exits 0"              0 "$rc"
    assert_contains     "file/literal-%: binds literal % path" "SANDBOX_PATH_0=$scratch/%literal.txt" "$stdout"
    assert_not_contains "file/literal-%: no printf noise"      "missing hex" "$stdout"

    # Stray % in a file:// URL: must not crash, must not leak printf noise.
    stdout=$(${fileLauncher} "file://$scratch/with%xx.txt" 2>&1); rc=$?
    assert_exit         "file/stray-%: exits 0 (skipped)"     0 "$rc"
    assert_not_contains "file/stray-%: no printf noise"       "missing hex" "$stdout"

    # Multi-file in file mode: each file gets its own slot, in arg order.
    stdout=$(${fileLauncher} "$scratch/file.txt" "$scratch/sibling.txt" 2>&1); rc=$?
    assert_exit     "file/multi: exits 0"                    0 "$rc"
    assert_contains "file/multi: first slot bound"           "SANDBOX_PATH_0=$scratch/file.txt" "$stdout"
    assert_contains "file/multi: second slot bound"          "SANDBOX_PATH_1=$scratch/sibling.txt" "$stdout"

    # Overflow: more than 16 distinct file paths refuses with a hint.
    overflow=()
    for i in $(seq 1 17); do
      echo "ov" > "$scratch/over$i.txt"
      overflow+=("$scratch/over$i.txt")
    done
    stdout=$(${fileLauncher} "''${overflow[@]}" 2>&1); rc=$?
    assert_exit     "file/overflow: refuses (>16)"           1 "$rc"
    assert_contains "file/overflow: clear error"             "too many path arguments" "$stdout"

    # --- dir mode ---

    stdout=$(${dirLauncher} "$scratch/file.txt" 2>&1); rc=$?
    assert_exit     "dir/file: exits 0"                      0 "$rc"
    assert_contains "dir/file: binds parent dir"             "SANDBOX_PATH_0=$scratch" "$stdout"
    assert_contains "dir/file: arg is canonical file"        "ARG=$scratch/file.txt" "$stdout"

    stdout=$(${dirLauncher} "$scratch" 2>&1); rc=$?
    assert_exit     "dir/dir: exits 0"                       0 "$rc"
    assert_contains "dir/dir: binds dir as-is"               "SANDBOX_PATH_0=$scratch" "$stdout"

    stdout=$(cd "$scratch" && ${dirLauncher} 2>&1); rc=$?
    assert_exit         "dir/none: exits 0"                  0 "$rc"
    assert_contains     "dir/none: falls back to \$PWD"      "SANDBOX_PATH_0=$scratch" "$stdout"
    assert_not_contains "dir/none: no fallback warning"      "no argument resolved" "$stdout"

    stdout=$(${dirLauncher} "/" 2>&1); rc=$?
    assert_exit     "dir//: refuses"                         1 "$rc"
    assert_contains "dir//: clear error"                     "filesystem root" "$stdout"

    stdout=$(${dirLauncher} "$HOME" 2>&1); rc=$?
    assert_exit     "dir/HOME: refuses"                      1 "$rc"
    assert_contains "dir/HOME: clear error"                  "would cover \$HOME" "$stdout"

    stdout=$(${dirLauncher} "$HOME/home-file.txt" 2>&1); rc=$?
    assert_exit     "dir/file-in-HOME: refuses (parent=\$HOME)" 1 "$rc"

    # Parent of $HOME — must also be refused.
    parent_of_home=$(dirname -- "$HOME")
    if [ "$parent_of_home" != "/" ] && [ "$parent_of_home" != "$HOME" ]; then
      stdout=$(${dirLauncher} "$parent_of_home" 2>&1); rc=$?
      assert_exit     "dir/parent-of-HOME: refuses (ancestor)"   1 "$rc"
      assert_contains "dir/parent-of-HOME: clear error"          "would cover \$HOME" "$stdout"
    fi

    stdout=$(${dirLauncher} "$HOME/safe-subdir" 2>&1); rc=$?
    assert_exit     "dir/HOME-subdir: allowed"               0 "$rc"
    assert_contains "dir/HOME-subdir: binds subdir"          "SANDBOX_PATH_0=$HOME/safe-subdir" "$stdout"

    # HOME unset: previously crashed on set -u in the tilde branch and the
    # home_canon check. Both now default $HOME to "/".
    stdout=$(env -u HOME -- ${dirLauncher} "$scratch/file.txt" 2>&1); rc=$?
    assert_exit     "dir/HOME-unset: exits 0"                0 "$rc"
    assert_contains "dir/HOME-unset: bind still works"       "SANDBOX_PATH_0=$scratch" "$stdout"

    # Non-existent / typo'd path: warning emitted, dir mode falls back to PWD.
    stdout=$(cd "$scratch" && ${dirLauncher} "/non/exist/ent" 2>&1); rc=$?
    assert_exit     "dir/non-existent: exits 0"              0 "$rc"
    assert_contains "dir/non-existent: warning"              "no argument resolved" "$stdout"
    assert_contains "dir/non-existent: falls back to PWD"    "SANDBOX_PATH_0=$scratch" "$stdout"

    # --- multi-path in dir mode ---

    # Two files sharing a parent → dedup to a single slot.
    stdout=$(${dirLauncher} "$scratch/file.txt" "$scratch/sibling.txt" 2>&1); rc=$?
    assert_exit         "dir/dedup: exits 0"                     0 "$rc"
    assert_contains     "dir/dedup: parent bound once"           "SANDBOX_PATH_0=$scratch" "$stdout"
    assert_not_contains "dir/dedup: no spurious second slot"     "SANDBOX_PATH_1=" "$stdout"

    # Two files in different parents → two slots, in arg order.
    stdout=$(${dirLauncher} "$scratch/file.txt" "$scratch/subdir/nested.txt" 2>&1); rc=$?
    assert_exit     "dir/two-paths: exits 0"                 0 "$rc"
    assert_contains "dir/two-paths: first parent bound"      "SANDBOX_PATH_0=$scratch" "$stdout"
    assert_contains "dir/two-paths: second parent bound"     "SANDBOX_PATH_1=$scratch/subdir" "$stdout"

    # Dir-mode refusal during multi-path: one valid + one HOME-covering →
    # whole launch refuses (better than silently exposing the valid one).
    stdout=$(${dirLauncher} "$scratch/file.txt" "$HOME" 2>&1); rc=$?
    assert_exit     "dir/multi+HOME: refuses whole launch"   1 "$rc"
    assert_contains "dir/multi+HOME: clear error"            "would cover \$HOME" "$stdout"

    # --- misc / regression ---

    stdout=$(cd "$scratch" && ${dirLauncher} "" "$scratch/file.txt" 2>&1); rc=$?
    assert_exit     "dir/empty+path: exits 0 (empty skipped)" 0 "$rc"
    assert_contains "dir/empty+path: binds the real path"     "SANDBOX_PATH_0=$scratch" "$stdout"

    # Non-ASCII filename: Arabic + emoji + spaces + literal `#`. Bash +
    # Linux pathnames are byte-transparent; the launcher should pass the
    # bytes through verbatim. Regression test for the worry that case
    # patterns or parameter expansion mangles multi-byte sequences.
    unicode_name="هاي اني من نجحت🤣#جامعة_القاسم_الخضراء #جامعة.mp4"
    echo "data" > "$scratch/$unicode_name"

    stdout=$(${fileLauncher} "$scratch/$unicode_name" 2>&1); rc=$?
    assert_exit     "file/unicode: exits 0"                   0 "$rc"
    assert_contains "file/unicode: binds the file verbatim"   "SANDBOX_PATH_0=$scratch/$unicode_name" "$stdout"
    assert_contains "file/unicode: arg preserved verbatim"    "ARG=$scratch/$unicode_name" "$stdout"

    stdout=$(${dirLauncher} "$scratch/$unicode_name" 2>&1); rc=$?
    assert_exit     "dir/unicode: exits 0"                    0 "$rc"
    assert_contains "dir/unicode: parent dir bound"           "SANDBOX_PATH_0=$scratch" "$stdout"
    assert_contains "dir/unicode: canonical arg verbatim"     "ARG=$scratch/$unicode_name" "$stdout"

    # Same name via file:// URL with bytes that need encoding percent-
    # escaped (space → %20, # → %23). Arabic + emoji bytes are passed
    # through unencoded, which is what most apps emit.
    unicode_url_name="هاي%20اني%20من%20نجحت🤣%23جامعة_القاسم_الخضراء%20%23جامعة.mp4"
    stdout=$(${fileLauncher} "file://$scratch/$unicode_url_name" 2>&1); rc=$?
    assert_exit     "file/unicode-url: exits 0"               0 "$rc"
    assert_contains "file/unicode-url: decodes to real path"  "SANDBOX_PATH_0=$scratch/$unicode_name" "$stdout"

    printf '\n--- %d passed, %d failed ---\n' "$PASS" "$FAIL"
    if [ "$FAIL" -gt 0 ]; then
      exit 1
    fi
    touch $out
  ''
