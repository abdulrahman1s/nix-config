{ pkgs, lib, username, ... }:

let
  extensionsRepo = pkgs.fetchFromGitHub {
    owner = "vicinaehq";
    repo = "extensions";
    rev = "77e680840be57246023a60b4b3a5898e117bc1aa";
    hash = "sha256-eVWtcqCL+ipCwugK0T9Kk98T1MmWd56X2quMCuuwtTE=";
  };

  mkVicinaeExtension =
    { pname, version ? "0", src, ... }@attrs:
    pkgs.buildNpmPackage (
      (removeAttrs attrs [ "pname" "version" "src" ])
      // {
        inherit pname version src;
        npmDeps = attrs.npmDeps or (pkgs.importNpmLock { npmRoot = src; });
        npmConfigHook = attrs.npmConfigHook or pkgs.importNpmLock.npmConfigHook;
        buildPhase = attrs.buildPhase or "npm run build -- --out=$out";
        dontNpmInstall = attrs.dontNpmInstall or true;
      }
    );

  mkRayCastExtension =
    { name, src ? null, rev ? null, hash ? null, sha256 ? null, ... }@attrs:
    let
      resolvedSrc =
        if src != null then
          src
        else
          pkgs.fetchFromGitHub
            {
              owner = "raycast";
              repo = "extensions";
              rev =
                if rev != null then
                  rev
                else
                  throw "mkRayCastExtension: `rev` is required when src isn't supplied";
              hash =
                if hash != null then
                  hash
                else if sha256 != null then
                  sha256
                else
                  throw "mkRayCastExtension: `hash` or `sha256` is required";
              sparseCheckout = [ "/extensions/${name}" ];
            }
          + "/extensions/${name}";
    in
    pkgs.buildNpmPackage (
      (removeAttrs attrs [ "name" "src" "rev" "hash" "sha256" ])
      // {
        inherit name;
        src = resolvedSrc;
        npmDeps = attrs.npmDeps or (pkgs.importNpmLock { npmRoot = resolvedSrc; });
        npmConfigHook = attrs.npmConfigHook or pkgs.importNpmLock.npmConfigHook;
        installPhase = attrs.installPhase or ''
          runHook preInstall

          pkgName=$(node -p "require('./package.json').name")
          mkdir -p $out
          cp -r /build/.config/raycast/extensions/"$pkgName"/* $out/

          runHook postInstall
        '';
      }
    );

  extensions = {
    stocks = mkVicinaeExtension {
      pname = "vicinae-extension-stocks";
      src = "${extensionsRepo}/extensions/stocks";
    };
    port-killer = mkVicinaeExtension {
      pname = "vicinae-extension-port-killer";
      src = "${extensionsRepo}/extensions/port-killer";
    };

    nix = mkVicinaeExtension {
      pname = "vicinae-extension-nix";
      src = "${extensionsRepo}/extensions/nix";
    };

    podman = mkVicinaeExtension {
      pname = "vicinae-extension-podman";
      src = "${extensionsRepo}/extensions/podman";
    };

    google-search = mkRayCastExtension {
      name = "google-search";
      rev = "870667fc671801a467deb7c4c7fc72992efe3820";
      hash = "sha256-yqY2OliYYHHW7TiCsrbb8qxEHJhY2gRZ90ZlDxHmUng=";
    };

    google-translate = mkRayCastExtension {
      name = "google-translate";
      rev = "870667fc671801a467deb7c4c7fc72992efe3820";
      hash = "sha256-xTA6Aa+cTmpGu80BokfFaHCGWOLCSWE1SrYhqSOi/Jo=";
    };
  };

  extDir = "/home/${username}/.local/share/vicinae/extensions";
in
{
  systemd.tmpfiles.rules =
    [
      "d /home/${username}/.local/share/vicinae 0755 ${username} users -"
      "d ${extDir} 0755 ${username} users -"
    ]
    ++ lib.mapAttrsToList (name: drv: "L+ ${extDir}/${name} - - - - ${drv}") extensions;
}
