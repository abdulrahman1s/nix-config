{ lib, pkgs, username, ... }:

let
  cuda = pkgs.cudaPackages;
  cudaMajorVersion = lib.versions.major cuda.cuda_cudart.version;
  cudaToolkit = pkgs.buildEnv {
    name = "ollama-cuda-toolkit-${cudaMajorVersion}";
    paths = [
      cuda.cuda_cudart
      (lib.getOutput "static" cuda.cuda_cudart)
      (lib.getDev cuda.libcublas)
      (lib.getLib cuda.libcublas)
      cuda.cccl
      (lib.getBin (cuda.cuda_nvcc.__spliced.buildHost or cuda.cuda_nvcc))
    ];
    ignoreCollisions = true;
  };

  ollamaCuda = pkgs.ollama-cuda.overrideAttrs (old: {
    # The CUDA setup hook exports CUDAToolkit_ROOT as a list of split outputs,
    # but llama.cpp's CUDA discovery requires one root containing nvcc.
    preBuild = ''
      export CUDAToolkit_ROOT='${cudaToolkit}'

      cmake -B build \
        -DCMAKE_SKIP_BUILD_RPATH=ON \
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
        -DFETCHCONTENT_SOURCE_DIR_LLAMA_CPP="$TMPDIR/llama-cpp-src" \
        -DOLLAMA_MLX_BACKENDS="" \
        $cmakeFlags \
        -DCUDAToolkit_ROOT='${cudaToolkit}' \
        -DCMAKE_CUDA_ARCHITECTURES='120' \
        -DOLLAMA_LLAMA_BACKENDS=cuda_v${cudaMajorVersion}

      cmake --build build -j $NIX_BUILD_CORES
    '';
  });
in
{
  services.ollama = {
    enable = true;
    package = ollamaCuda;
    modelsDir = "/mnt/990Pro/ollama";
    user = "ollama";
  };

  users.users.${username}.packages = with pkgs; [
    # Add cuda support
    #    (llama-cpp.override { cudaSupport = true; })

    # llama-cpp


    # lmstudio
    # gemini-cli-bin
    #  claude-code
    codex
    rtk # CLI proxy that reduces LLM token consumption by 60-90% on common dev commands. 
    # vllm
  ];
}
