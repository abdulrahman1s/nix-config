{ lib, stdenvNoCC, fetchFromGitHub }:

stdenvNoCC.mkDerivation {
  pname = "labwc-themes";
  version = "0-unstable-2026-11-08";

  src = fetchFromGitHub {
    owner = "labwc";
    repo = "labwc-themes";
    rev = "6a2e3634eef03e7f124359ad28ed5da2d931f96d";
    hash = "sha256-5kCYm3qo7TQif/9aTViDozX/AO+kfoiipTJfPIBcu3g=";
  };

  # Upstream's Makefile and meson.build only copy each theme directory into
  # place, so this data-only package copies them itself without a toolchain.
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -d "$out/share/themes"
    cp -r lab* "$out/share/themes/"
    runHook postInstall
  '';

  meta = {
    description = "Server-side decoration themes for labwc";
    homepage = "https://github.com/labwc/labwc-themes";
    license = lib.licenses.cc-by-sa-40;
    platforms = lib.platforms.all;
  };
}
