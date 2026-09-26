{ config, lib, pkgs, username, ... }:

let
  cfg = config.personal-ai.localLlm;

  llamaCppCuda = pkgs.llama-cpp.override {
    cudaSupport = true;
  };

  localLlmSmokeTest = pkgs.writeShellApplication {
    name = "ai-local-smoke-test";
    runtimeInputs = with pkgs; [ curl gnugrep jq systemd ];
    text = ''
      set -euo pipefail

      systemctl is-active --quiet llama-cpp.service || {
        echo "llama-cpp.service is not active. Select personal-ai.localLlm.modelPath and rebuild first." >&2
        exit 1
      }

      response="$(curl --fail --silent --show-error \
        --header 'Content-Type: application/json' \
        --data '{"model":"local-private","messages":[{"role":"user","content":"Reply with exactly: LOCAL_LLM_OK"}],"temperature":0,"max_tokens":256}' \
        http://127.0.0.1:${toString cfg.port}/v1/chat/completions)"

      content="$(printf '%s' "$response" | jq -er '.choices[0].message.content')"
      printf '%s\n' "$content" | grep -Fq 'LOCAL_LLM_OK' || {
        echo "Local model returned an unexpected response: $content" >&2
        exit 1
      }

      ${lib.getExe' config.hardware.nvidia.package "nvidia-smi"} \
        --query-compute-apps=process_name,used_memory --format=csv,noheader,nounits \
        | grep -F 'llama-server' >/dev/null || {
          echo "The request succeeded, but llama-server was not visible as an NVIDIA compute process." >&2
          exit 1
        }

      echo "Local llama.cpp inference passed and used the NVIDIA GPU."
    '';
  };
in
{
  options.personal-ai.localLlm = {
    modelPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "/mnt/990Pro/ai-models/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q6_K.gguf";
      description = "Absolute path to the selected local GGUF model.";
    };
    mmprojPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional GGUF multimodal projector for private screenshot/image understanding.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 11434;
      description = "Loopback port for llama.cpp's OpenAI-compatible server.";
    };
    contextSize = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = 32768;
      description = "llama.cpp context size; bounded to leave GPU headroom for the desktop.";
    };
    flashAttention = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Optional model-specific llama.cpp flash-attention setting.";
    };
  };

  config = {
    assertions = lib.optional config.personal-ai.enable {
      assertion = cfg.modelPath != null;
      message = "personal-ai.enable requires personal-ai.localLlm.modelPath; choose the GGUF first.";
    };

    services.llama-cpp = {
      enable = config.personal-ai.enable && cfg.modelPath != null;
      package = llamaCppCuda;
      settings = {
        host = "127.0.0.1";
        port = cfg.port;
        metrics = true;
        jinja = true;
        "n-gpu-layers" = 999;
        parallel = 1;
        "sleep-idle-seconds" = 300;
      }
      // lib.optionalAttrs (cfg.modelPath != null) {
        model = cfg.modelPath;
      }
      // lib.optionalAttrs (cfg.mmprojPath != null) {
        mmproj = cfg.mmprojPath;
      }
      // lib.optionalAttrs (cfg.contextSize != null) {
        "ctx-size" = cfg.contextSize;
      }
      // lib.optionalAttrs (cfg.flashAttention != null) {
        "flash-attn" = if cfg.flashAttention then "on" else "off";
      };
    };

    systemd.services.llama-cpp = lib.mkIf (config.personal-ai.enable && cfg.modelPath != null) {
      unitConfig.RequiresMountsFor = [ cfg.modelPath ] ++ lib.optional (cfg.mmprojPath != null) cfg.mmprojPath;
      serviceConfig = {
        Restart = "on-failure";
        RestartSec = lib.mkForce 5;
      };
    };

    users.users.${username}.packages = lib.optionals config.personal-ai.enable [ llamaCppCuda localLlmSmokeTest ];
  };
}
