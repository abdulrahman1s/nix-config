{ config, lib, pkgs, ... }:

let
  cfg = config.personal-ai;
  runtimePath = lib.makeBinPath (with pkgs; [
    coreutils
    tesseract
    wl-clipboard
  ]);
  openaiBackend = pkgs.writeShellScript "personal-ai-openai-backend" ''
    export PATH=${runtimePath}:/run/current-system/sw/bin
    export PERSONAL_AI_OPENAI_BASE_URL=${lib.escapeShellArg cfg.workflows.openai.baseUrl}
    export PERSONAL_AI_OPENAI_API_KEY=${lib.escapeShellArg cfg.workflows.openai.apiKey}
    export PERSONAL_AI_PRIVATE_MODEL=${lib.escapeShellArg cfg.workflows.openai.privateModel}
    export PERSONAL_AI_PUBLIC_MODEL=${lib.escapeShellArg cfg.workflows.openai.publicModel}
    export PERSONAL_AI_VISION_MODEL=${lib.escapeShellArg cfg.workflows.openai.visionModel}
    exec ${lib.getExe pkgs.bun} ${../backends/openai.ts}
  '';
  runner = pkgs.writeShellScript "personal-ai-workflow-runner" ''
    export PATH=${runtimePath}:/run/current-system/sw/bin
    export PERSONAL_AI_MODEL_BACKEND=${lib.escapeShellArg cfg.workflows.backendCommand}
    exec ${lib.getExe pkgs.bun} ${./.}/index.ts
  '';
in
{
  options.personal-ai.workflowRunner = lib.mkOption {
    type = lib.types.package;
    internal = true;
    readOnly = true;
    description = "Internal Bun workflow runner used by the Vicinae extension.";
  };

  options.personal-ai.workflows.backendCommand = lib.mkOption {
    type = lib.types.str;
    default = toString openaiBackend;
    description = ''
      Executable implementing the Personal AI model backend protocol: read a
      JSON object containing prompt, route, and optional image from stdin, then
      write the model response to stdout.
    '';
  };

  options.personal-ai.workflows.openai = {
    baseUrl = lib.mkOption { type = lib.types.str; default = "http://127.0.0.1:4100/v1"; };
    apiKey = lib.mkOption { type = lib.types.str; default = "local-router-no-secret"; };
    privateModel = lib.mkOption { type = lib.types.str; default = "privacy-auto"; };
    publicModel = lib.mkOption { type = lib.types.str; default = "public-bypass"; };
    visionModel = lib.mkOption { type = lib.types.str; default = "vision-online"; };
  };

  config = lib.mkIf cfg.enable {
    personal-ai.workflowRunner = runner;

  };
}
