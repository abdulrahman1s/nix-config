{ stdenvNoCC, fetchurl, lib, codex }:
stdenvNoCC.mkDerivation {
  pname = "codex";
  inherit (codex) version;

  src = fetchurl {
    url = "https://github.com/openai/codex/releases/download/rust-v${codex.version}/codex-package-x86_64-unknown-linux-musl.tar.gz";
    hash = codex.hash;
  };

  sourceRoot = ".";
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -R . $out/
    # sourceRoot "." is the build directory, so the copy includes stdenv's
    # env-vars file. It names the release tarball and would keep all 150 MiB
    # of it in every closure that has Codex.
    rm $out/env-vars
    ln -s bin/codex $out/codex
    runHook postInstall
  '';

  meta = {
    description = "OpenAI Codex command line interface";
    homepage = "https://github.com/openai/codex";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
    mainProgram = "codex";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
