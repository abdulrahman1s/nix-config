{ lib, stdenv, fetchFromGitHub, kernel, kernelModuleMakeFlags }:

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
    make ${lib.escapeShellArgs kernelModuleMakeFlags} \
      KDIR=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build module
    # Userspace binaries need the wrapped compiler's libc and linker setup.
    make wireviewd wireviewctl
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    # Kbuild installs the module with the kernel's signing and compression rules,
    # including the certificate needed when assembling the system's modules.
    make ${lib.escapeShellArgs kernelModuleMakeFlags} \
      -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
      M="$PWD" INSTALL_MOD_PATH="$out" INSTALL_MOD_DIR=extra \
      INSTALL_MOD_STRIP=1 modules_install
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
