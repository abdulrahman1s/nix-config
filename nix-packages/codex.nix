{ stdenvNoCC, fetchurl, lib, codex }:
stdenvNoCC.mkDerivation {
  pname = "codex";
  inherit (codex) version;

  src = fetchurl {
    url = "https://github.com/openai/codex/releases/download/rust-v${codex.version}/codex-x86_64-unknown-linux-musl.tar.gz";
    hash = codex.hash;
  };

  sourceRoot = ".";
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    install -Dm755 codex-x86_64-unknown-linux-musl $out/bin/codex
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
