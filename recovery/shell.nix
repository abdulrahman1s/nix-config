# The main system's terminal setup: zsh with the same prompt, plugins, history,
# aliases (claudex, codexx, ...) and functions, the same Ghostty settings, and
# Claude Code and Codex. Everything is read from the main configuration, so
# changes there reach the recovery with the next recovery-update.
{ inputs, lib, pkgs, username, ... }:
let
  mainConfig = inputs.self.nixosConfigurations.default.config;
  mainZsh = mainConfig.programs.zsh;
  maintainedPackages = inputs.self.packages.${pkgs.stdenv.hostPlatform.system};

  # Commands the main shell settings call by name. Its init script already
  # names the store paths it sources, so those come along by themselves.
  shellCommands = [
    "atuin"
    "direnv"
    "eza"
    "fzf"
    "neovim"
    "pure-prompt"
    "qsh-prebuilt"
    "zoxide"
  ];

  # labwc draws title bars, and the recovery relies on their buttons; the main
  # system's niri setup turns Ghostty's own decorations off.
  ghosttyConfig = pkgs.writeText "ghostty-config" ''
    ${builtins.readFile ../config/ghostty/config}
    # Recovery: keep title bars so windows can be closed with the mouse.
    window-decoration = auto
  '';
in
{
  users.defaultUserShell = pkgs.zsh;

  programs.zsh = {
    enable = true;
    inherit (mainZsh)
      histSize
      histFile
      setOptions
      shellAliases
      enableCompletion
      promptInit
      ;
    # The merged init already loads autosuggestions, syntax highlighting,
    # direnv, atuin and qsh, so those options stay off here to avoid loading
    # them twice.
    interactiveShellInit = mainZsh.interactiveShellInit;
  };

  environment = {
    systemPackages =
      lib.filter (package: lib.elem (lib.getName package) shellCommands) mainConfig.environment.systemPackages
      ++ [
        maintainedPackages.claude-code
        maintainedPackages.codex
        # Codex runs commands in a bubblewrap sandbox and warns when it has to
        # fall back to its bundled copy.
        pkgs.bubblewrap
      ];
    sessionVariables = {
      inherit (mainConfig.environment.sessionVariables) EDITOR VISUAL;
    };
    variables = {
      inherit (mainConfig.environment.variables) ATUIN_CONFIG_DIR DIRENV_CONFIG;
    };
    etc =
      lib.genAttrs
        [
          "atuin/config.toml"
          "direnv/direnv.toml"
          "direnv/direnvrc"
          "direnv/lib/zz-user.sh"
        ]
        (name: { inherit (mainConfig.environment.etc.${name}) source; })
      // {
        "nixos-recovery/zsh/common.zsh".source = ../config/zsh/common.zsh;
        "nixos-recovery/ghostty/config".source = ghosttyConfig;
        # Tells Claude Code and Codex they run on the recovery system and how
        # to work safely there. Claude Code loads its managed CLAUDE.md in
        # every session, from any directory and for every user. Codex has no
        # system-wide instructions file, so ~/.codex/AGENTS.md links here.
        # The source isn't named AGENTS.md: Codex would apply it to any
        # session started in recovery/ on the main system.
        "claude-code/CLAUDE.md".source = ./docs/assistant-instructions.md;
        "nixos-recovery/AGENTS.md".source = ./docs/assistant-instructions.md;
      };
  };

  # The main system runs prebuilt binaries, such as qsh from its zsh init,
  # through nix-ld.
  programs.nix-ld = {
    enable = true;
    inherit (mainConfig.programs.nix-ld) libraries;
  };

  # Ghostty's font, and the icons eza shows in listings.
  fonts.packages = [ pkgs.nerd-fonts.fira-code ];

  # Claude Code and Codex start signed in: recovery-update copies their logins
  # from the main system's home (apps/recovery-update.sh).
  system.userActivationScripts.recovery-shell-config.text = ''
    # An empty ~/.zshrc stops zsh's new-user wizard; the configuration is in
    # /etc/zshrc, as on the main system.
    touch "$HOME/.zshrc"

    for pair in \
      .config/zsh/common.zsh:/etc/nixos-recovery/zsh/common.zsh \
      .config/ghostty/config:/etc/nixos-recovery/ghostty/config \
      .codex/AGENTS.md:/etc/nixos-recovery/AGENTS.md; do
      link="$HOME/''${pair%%:*}"
      mkdir -p "$(dirname "$link")"
      if [[ -e $link && ! -L $link ]]; then
        mv -- "$link" "$link.$(date +%s).bak"
      fi
      ln -sfn "''${pair#*:}" "$link"
    done
  '';

  assertions = [
    {
      assertion = lib.all (name: lib.any (package: lib.getName package == name) mainConfig.environment.systemPackages) shellCommands;
      message = "recovery/shell.nix: a command the main zsh settings use is no longer installed on the main system.";
    }
  ];
}
