{ lib, stdenvNoCC, fetchurl, unzip, autoPatchelfHook, addDriverRunpath, stdenv }:

stdenvNoCC.mkDerivation {
  pname = "nvidia-vfx";
  version = "0.2.0.0";

  src = fetchurl {
    url = "https://pypi.nvidia.com/nvidia-vfx/nvidia_vfx-0.2.0.0-cp312-abi3-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl";
    hash = "sha256-AlKGant5im+SyFQ0Q9iPcW6MW7xqfd13onVHKNran6g=";
  };

  nativeBuildInputs = [ unzip autoPatchelfHook addDriverRunpath ];
  buildInputs = [ stdenv.cc.cc.lib ];
  dontUnpack = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;
  dontAutoPatchelf = true;

  # libcuda comes from the running driver, which is absent in the build sandbox.
  autoPatchelfIgnoreMissingDeps = [ "libcuda.so.1" ];
  appendRunpaths = [ "${addDriverRunpath.driverLink}/lib" ];

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    unzip -q "$src" 'nvvfx/libs/*' 'nvidia_vfx.libs/*' '*dist-info/licenses/*' -d "$out"
    # The loader uses unversioned names; retain the wheel's relative layout for
    # its private CUDA runtime in nvidia_vfx.libs.
    for library in "$out"/nvvfx/libs/*.so.*; do
      link="''${library%%.so.*}.so"
      if [ ! -e "$link" ]; then
        ln -s "$(basename "$library")" "$link"
      fi
    done
    runHook postInstall
  '';

  postFixup = ''
    # NGX verifies signatures on these backends. Even changing an ELF RPATH
    # invalidates the signature, so keep them byte-for-byte as NVIDIA shipped.
    addAutoPatchelfSearchPath "$out"
    mapfile -d ''' libraries < <(find "$out" -type f -name '*.so*' \
      ! -name 'libnvidia-ngx-*' -print0)
    autoPatchelf "''${libraries[@]}"
  '';

  # The early-access SDK must not be redistributed through binary caches.
  dontDistribute = true;
  preferLocalBuild = true;
  allowSubstitutes = false;

  meta = {
    description = "NVIDIA Video Effects SDK runtime for RTX Video Super Resolution";
    homepage = "https://docs.nvidia.com/maxine/vfx/latest/";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
