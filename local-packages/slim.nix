{ lib
, stdenv
, fetchurl
, autoPatchelfHook
}:

stdenv.mkDerivation rec {
  pname = "slim";
  version = "0.9.1";

  src = fetchurl {
    url = "https://github.com/nilbuild/slim/releases/download/${version}/slim_${version}_linux_amd64.tar.gz";
    hash = "sha256-1VuZuYinnNPR8AEKDZfujaKLbRJjYqi7YcwF896Qr4s=";
  };

  sourceRoot = ".";
  nativeBuildInputs = [ autoPatchelfHook ];

  installPhase = ''
    runHook preInstall

    install -Dm755 slim $out/bin/slim

    runHook postInstall
  '';

  meta = {
    description = "Give localhost services clean HTTPS domains";
    homepage = "https://github.com/nilbuild/slim";
    license = lib.licenses.unfreeRedistributable; # PolyForm Shield 1.0.0
    mainProgram = "slim";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
