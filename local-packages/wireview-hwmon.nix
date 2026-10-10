{ lib, stdenv, fetchFromGitHub, kernel }:

stdenv.mkDerivation rec {
  pname = "wireview-hwmon";
  version = "1.7.1";

  src = fetchFromGitHub {
    owner = "emaspa";
    repo = "wireview-hwmon";
    rev = "v${version}";
    hash = "sha256-ivn8fhJrSSCnnhNV1XWA8JqmZkcjuDAAwX5+Ag4Hso0=";
  };

  nativeBuildInputs = kernel.moduleBuildDependencies;
  hardeningDisable = [ "pic" ];

  buildPhase = ''
    runHook preBuild
    make KDIR=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build all
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 wireview_hwmon.ko "$out/lib/modules/${kernel.modDirVersion}/extra/wireview_hwmon.ko"
    install -Dm755 wireviewd "$out/bin/wireviewd"
    install -Dm755 wireviewctl "$out/bin/wireviewctl"
    runHook postInstall
  '';

  meta = {
    description = "WireView Pro II Linux hwmon module, daemon, and CLI";
    homepage = "https://github.com/emaspa/wireview-hwmon";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
    mainProgram = "wireviewctl";
  };
}
