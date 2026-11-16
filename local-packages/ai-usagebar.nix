{ lib, stdenv, fetchurl, autoPatchelfHook }:

stdenv.mkDerivation {
  pname = "ai-usagebar";
  version = "1.41.0";

  src = fetchurl {
    url = "https://github.com/akitaonrails/ai-usagebar/releases/download/v1.41.0/ai-usagebar-linux-x86_64.tar.gz";
    hash = "sha256-eg63zcl2DSiuzKveE/o4VNNtb7ofd6rmtnl67fkJyrI=";
  };

  sourceRoot = ".";
  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib ];
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 ai-usagebar "$out/bin/ai-usagebar"
    install -Dm755 ai-usagebar-tui "$out/bin/ai-usagebar-tui"
    install -Dm644 LICENSE "$out/share/licenses/ai-usagebar/LICENSE"
    runHook postInstall
  '';

  # The Linux CLI has no self-updater; releases are managed here.
  meta = {
    description = "AI plan usage CLI for Noctalia's AI Usage plugin";
    homepage = "https://github.com/akitaonrails/ai-usagebar";
    license = lib.licenses.mit;
    mainProgram = "ai-usagebar";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
