{ config, lib, pkgs, ... }:

let
  cfg = config.personal-ai;
  cloudConfigured = cfg.cloud.fastModel != null && cfg.cloud.strongModel != null;
  switchModelList = lib.mapAttrsToList (name: model: {
    model_name = "model-${lib.replaceStrings [ ":" ] [ "-" ] name}";
    litellm_params.model = model;
  }) cfg.cloud.switchModels;

  # Our nixpkgs pin ships litellm 1.97.0, which dies at startup with fastapi
  # >= 0.140 (get_flat_dependant was removed). nixpkgs fixed this in 1.98.0
  # (commit 22a509a4); replicate that bump on our pin until the flake input
  # catches up.
  litellmFixed = pkgs.litellm.overridePythonAttrs (old: rec {
    version = "1.98.0";
    src = old.src.override {
      tag = "v${version}";
      hash = "sha256-eMquDSSlBo//huXXiys/F36O18VDjv7U1OUe7DrKhus=";
    };
    cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
      inherit (old) pname cargoRoot;
      inherit version src;
      hash = "sha256-iwgIclG8BGeHDNtm686w2Rxe+9ddvBrz1sMfOBeuKK0="; # Cargo.lock unchanged upstream
    };
    # litellm 1.98 imports boto3 unconditionally but still pins it under the
    # proxy extra; provide it and drop the pin so the env check stays happy.
    dependencies = old.dependencies ++ [ pkgs.python3.pkgs.boto3 ];
    pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "boto3" ];
    postPatch = let inheritedPostPatch = old.postPatch or ""; in inheritedPostPatch + ''
      substituteInPlace litellm/llms/openrouter/chat/transformation.py \
        --replace-fail \
          'new_choices: Final = []' \
          'new_choices: Final = []
                  provider_specific_fields = None
                  if "openrouter_metadata" in chunk:
                      provider_specific_fields = {"openrouter_metadata": chunk["openrouter_metadata"]}
                      if not chunk["choices"]:
                          chunk["choices"] = [{"index": 0, "delta": {}, "finish_reason": None}]' \
        --replace-fail \
          'choices=new_choices,' \
          'choices=new_choices,
                      provider_specific_fields=provider_specific_fields,'
    '';
  });
in
{
  options.personal-ai = {
    enable = lib.mkEnableOption "the personal AI stack";

    cloud = {
      fastModel = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "openrouter/google/gemini-2.5-flash";
        description = "LiteLLM model identifier used for public latency/cost-oriented requests.";
      };

      strongModel = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "openrouter/anthropic/claude-sonnet-4";
        description = "LiteLLM model identifier used for public complex/reasoning requests.";
      };

      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        example = "/run/agenix/personal-ai-cloud-env";
        description = "Runtime environment file containing cloud provider API keys.";
      };

      switchModels = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {
          auto = "openrouter/auto";
          "gpt:cheap" = "openrouter/openai/gpt-5.6-luna";
          "gpt:balanced" = "openrouter/openai/gpt-5.6-terra";
          "gpt:best" = "openrouter/openai/gpt-5.6-sol";
          "deepseek:cheap" = "openrouter/deepseek/deepseek-v4.1-flash";
          "deepseek:balanced" = "openrouter/deepseek/deepseek-v4-pro-0813";
          "deepseek:best" = "openrouter/deepseek/deepseek-v4-pro-0813";
          "glm:cheap" = "openrouter/z-ai/glm-5.3-flash";
          "glm:balanced" = "openrouter/z-ai/glm-5";
          "glm:best" = "openrouter/z-ai/glm-5.3";
          "claude:cheap" = "openrouter/anthropic/claude-fable-5";
          "claude:balanced" = "openrouter/anthropic/claude-sonnet-5";
          "claude:best" = "openrouter/anthropic/claude-opus-5";
          "gemini:cheap" = "openrouter/google/gemini-3.5-flash-lite";
          "gemini:balanced" = "openrouter/google/gemini-3.8-flash";
          "gemini:best" = "openrouter/google/gemini-3-pro-preview";
          "grok:cheap" = "openrouter/x-ai/grok-4.3-fast";
          "grok:balanced" = "openrouter/x-ai/grok-4.5";
          "grok:best" = "openrouter/x-ai/grok-4.6";
          "kimi:cheap" = "openrouter/moonshotai/kimi-k2.5";
          "kimi:balanced" = "openrouter/moonshotai/kimi-k2.6";
          "kimi:best" = "openrouter/moonshotai/kimi-k3";
          "qwen:cheap" = "openrouter/qwen/qwen3.8-flash";
          "qwen:balanced" = "openrouter/qwen/qwen3.8-max-0902";
          "qwen:best" = "openrouter/qwen/qwen3.8-2.4t-a95b";
          "minimax:cheap" = "openrouter/minimax/minimax-m2.5";
          "minimax:balanced" = "openrouter/minimax/minimax-m2.7";
          "minimax:best" = "openrouter/minimax/minimax-m3";
        };
        description = "Models selected by model:<family>[:<flag>] prefixes.";
      };
    };
  };

  config = {
    # Mounted only when the stack is enabled so a disabled stack never decrypts it.
    age.secrets.personal-ai-cloud-env = lib.mkIf cfg.enable {
      file = ../../secrets/personal-ai-cloud-env.age;
    };

    assertions = lib.optionals cfg.enable [
      {
        assertion = cloudConfigured;
        message = "personal-ai.enable requires both cloud.fastModel and cloud.strongModel.";
      }
      {
        assertion = cfg.cloud.environmentFile != null;
        message = "personal-ai.enable requires cloud.environmentFile for LiteLLM credentials.";
      }
    ];

    services.litellm = {
      enable = cfg.enable && cloudConfigured;
      package = litellmFixed;
      host = "127.0.0.1";
      port = 4000;
      openFirewall = false;
      environmentFile = cfg.cloud.environmentFile;
      settings = {
        model_list = lib.optionals cloudConfigured ([
          {
            model_name = "public-fast";
            litellm_params.model = cfg.cloud.fastModel;
          }
          {
            model_name = "public-strong";
            litellm_params.model = cfg.cloud.strongModel;
          }
        ] ++ switchModelList);
        router_settings = {
          routing_strategy = "latency-based-routing";
          enable_pre_call_checks = true;
          num_retries = 2;
        };
        litellm_settings = {
          telemetry = false;
          redact_user_api_key_info = true;
          drop_params = true;
        };
        general_settings = {
          disable_spend_logs = false;
          disable_error_logs = false;
        };
      };
    };
  };
}
