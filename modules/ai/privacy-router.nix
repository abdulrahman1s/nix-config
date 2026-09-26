{ config, lib, pkgs, username, ... }:

let
  cfg = config.personal-ai;
  modelName = model: if model == null then "unconfigured" else lib.last (lib.splitString "/" model);
  localModelName =
    if cfg.localLlm.modelPath == null then "unconfigured"
    else lib.removeSuffix ".gguf" (baseNameOf cfg.localLlm.modelPath);
  routerPython = pkgs.python312.withPackages (ps: with ps; [ aiohttp ]);
  router = pkgs.writeShellApplication {
    name = "personal-ai-privacy-router";
    runtimeInputs = [ routerPython ];
    text = ''
      exec ${routerPython}/bin/python ${./privacy-router.py} "$@"
    '';
  };
  test = pkgs.writeShellApplication {
    name = "ai-privacy-tests";
    runtimeInputs = with pkgs; [ curl jq routerPython ];
    text = ''
      export PRIVACY_ROUTER_SOURCE=${./privacy-router.py}
      exec ${routerPython}/bin/python ${./tests/privacy_router_test.py}
    '';
  };
in
{
  options.personal-ai.privacy = {
    localEndpoint = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:11434/v1";
      description = "OpenAI-compatible local model endpoint used for private and uncertain requests.";
    };

    cloudEndpoint = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:4000/v1";
      description = "LiteLLM endpoint. Only locally-classified public payloads reach it.";
    };
  };

  config = {
    systemd.services.personal-ai-privacy-router = lib.mkIf cfg.enable {
      description = "Fail-closed local privacy and model routing gateway";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "llama-cpp.service" "litellm.service" ];
      wants = [ "llama-cpp.service" "litellm.service" ];
      environment = {
        LOCAL_LLM_URL = cfg.privacy.localEndpoint;
        LITELLM_URL = cfg.privacy.cloudEndpoint;
        LOCAL_MODEL_NAME = localModelName;
        CLOUD_FAST_MODEL_NAME = modelName cfg.cloud.fastModel;
        CLOUD_STRONG_MODEL_NAME = modelName cfg.cloud.strongModel;
        CONNECTIVITY_CHECK_URL = "https://openrouter.ai/api/v1/models";
        MODEL_SWITCHES = builtins.toJSON (lib.mapAttrs (_: modelName) cfg.cloud.switchModels);
        PRIVACY_ROUTER_HOST = "127.0.0.1";
        PRIVACY_ROUTER_PORT = "4100";
      };
      serviceConfig = {
        ExecStart = lib.getExe router;
        User = username;
        Group = "users";
        Restart = "on-failure";
        RestartSec = 3;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        UMask = "0077";
      };
    };

    users.users.${username}.packages = lib.optionals cfg.enable [ router test ];
  };
}
