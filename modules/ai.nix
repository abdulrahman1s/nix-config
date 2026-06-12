{ pkgs, username, ... }: {
  services.ollama = {
    enable = true;
    package = pkgs.ollama-cuda;
    models = "/mnt/990Pro/ollama";
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
