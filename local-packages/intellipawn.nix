{ lib, stdenv, fetchurl, unzip, autoPatchelfHook }:

stdenv.mkDerivation rec {
  pname = "intellipawn";
  version = "0.2.2";

  src = fetchurl {
    url = "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/ArSaCiAGame/vsextensions/intellipawn/${version}/vspackage";
    curlOptsList = [ "--compressed" ];
    hash = "sha256-qc1qABk5K/nuo0pyDT6BIT8IcKK2z1fm8TTrx/0f9uw=";
  };

  nativeBuildInputs = [ unzip autoPatchelfHook ];
  unpackPhase = ''
    unzip -q "$src"
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 extension/lsp-bin/pawn-lsp $out/bin/pawn-lsp
    install -Dm644 extension/lsp-bin/docs.json $out/bin/docs.json
    install -Dm644 extension/LICENSE.txt $out/share/licenses/intellipawn/LICENSE.txt
    runHook postInstall
  '';

  meta = {
    description = "Pawn language server with variable and include analysis for SA-MP";
    homepage = "https://marketplace.visualstudio.com/items?itemName=ArSaCiAGame.intellipawn";
    license = lib.licenses.mit;
    mainProgram = "pawn-lsp";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
