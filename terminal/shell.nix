{ pkgs, username, ... }:

let home = "/home/${username}"; in
{
  users.defaultUserShell = pkgs.zsh;

  programs.appimage = {
    enable = true;
    binfmt = true;
  };

  # Prevent zsh new-user wizard (all config is in /etc/zshrc via NixOS)
  system.userActivationScripts.zshrc.text = ''
    touch ~/.zshrc
  '';

  environment.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
    NIXPKGS_ALLOW_UNFREE = "1";
    GEMINI_MODEL = "gemini-3.5-flash";
  };

  programs.qsh = {
    enable = true;
    enableZshIntegration = true;
    enableBashIntegration = true;
    enableFishIntegration = true;
    prebuilt = {
      enable = true;
      version = "0.8.2";
      hash = "sha256-9I3Rs4nx19c60L1lhgtYa2Sru8d5U6MQa0eXP9Tsk2M=";
    };
  };

  programs.github-fs = {
    enable = true;
    autoMount = {
      enable = true;
      mountPath = "/home/${username}/Github";
      extraArgs = [
        "--log-level"
        "info"
      ];
    };

    prebuilt = {
      enable = true;
      version = "0.7.0";
      hash = "sha256-1Ycdgf1wiXLuqW/oRRhoNjTPT6mZveHI7p7yVr3dcKU=";
    };
  };


  # ~/.local/bin on PATH for all users
  environment.localBinInPath = true;

  # ── ZSH Configuration ─────────────────────────────────────
  programs.zsh = {
    enable = true;

    histSize = 100000;
    histFile = "$HOME/.zsh_history";
    setOptions = [
      "APPEND_HISTORY"
      "INC_APPEND_HISTORY"
      "SHARE_HISTORY"
      "EXTENDED_HISTORY"
      "HIST_IGNORE_ALL_DUPS" # de-dupe even if not consecutive
      "HIST_IGNORE_SPACE" # ` cmd` (leading space) → not saved. Great for secrets
      "HIST_REDUCE_BLANKS" # collapse runs of whitespace
      "HIST_VERIFY" # !! expansion shows you the command before running
      "HIST_FIND_NO_DUPS" # don't show dupes when searching
      "AUTOCD"
      "EXTENDED_GLOB"
      "NOMATCH"
      "NOTIFY"
      "INTERACTIVE_COMMENTS" # # comment works in interactive shell (paste-friendly)
      "COMPLETE_IN_WORD" # tab-complete in the middle of a word
      "ALWAYS_TO_END" # cursor goes to end after completion
      "NO_BEEP"
    ];

    shellAliases = {
      # Vim-style exit
      ":q" = "exit";
      ":wq" = "exit";

      # why not lol. 
      "please" = "sudo";
      "plz" = "sudo";

      # Navigation
      "home" = "cd ~";
      "~" = "cd ~";
      ".." = "cd ..";
      "...." = "cd ../..";

      # Editor
      vim = "nvim";
      v = "nvim";

      # Open image(s) in loupe
      see = "loupe";

      # Listing (eza — maintained exa fork)
      ls = "eza -la --icons --no-permissions --no-user --git --time-style=long-iso --sort=modified";
      claudex = "claude --dangerously-skip-permissions";
      tree = "eza --tree --icons";

      # File operations
      untar = "tar -xvf";
      sizeof = "du -sh";

      # Networking
      weather = "curl wttr.in/Egypt+Giza";

      download = "aria2c";
      dl = "aria2c";

      # System
      shh = "killall -KILL";

      json = "jnv";

      # NixOS management
      os = "just --justfile ${home}/system-conf/config/justfile";
      rebuild = "sudo nixos-rebuild switch --flake '${home}/system-conf#default'";
      flake-update = "nix flake update";
      flake-switch = "sudo nixos-rebuild switch --flake '${home}/system-conf#default'";
      nixos-cleanup = "sudo nix-collect-garbage -d && sudo nix-store --gc";


      # Misc
      drag = "blobdrop";
      iphone = "mkdir -p ~/iPhone && ifuse ~/iPhone";
      conf = "cd ~/system-conf && code .";
      "$" = ""; # allows pasting commands with a leading $
      why = "witr"; # Command-line tool to find out why processes are running
    };

    enableCompletion = true;
    autosuggestions.enable = true;
    syntaxHighlighting.enable = true;

    # ── Prompt (Pure) ────────────────────────────────────────
    promptInit = ''
      # Autoload prompt and URL magic functions all at once
      autoload -Uz promptinit url-quote-magic bracketed-paste-magic
      promptinit
      prompt pure
      # Bind URL escaping to typing and pasting
      zle -N self-insert url-quote-magic
      zle -N bracketed-paste bracketed-paste-magic
    '';

    # ── Interactive Shell Init ───────────────────────────────
    interactiveShellInit = ''
      # ── zsh-vi-mode ──────────────────────────────────────
      # Vim keybindings inside the prompt.
      #   Esc        → normal mode (h/j/k/l, w/b, dd, yy, p, ci", …)
      #   v          → open current line in $EDITOR (nvim)
      #   i / a / A  → back to insert mode
      # Note: rebinds the keymap on first prompt — custom bindkeys must
      # live in zvm_after_init() below to survive.
      source ${pkgs.zsh-vi-mode}/share/zsh-vi-mode/zsh-vi-mode.plugin.zsh

      # ── fzf key bindings ─────────────────────────────────
      #   Ctrl-R   fuzzy history search
      #   Ctrl-T   fuzzy file picker → inserts the path at the cursor
      #   Alt-C    fuzzy directory picker → cd into it
      source ${pkgs.fzf}/share/fzf/key-bindings.zsh

      # ── fzf completion trigger ───────────────────────────
      # Type `**` then Tab after a command (e.g. `vim **<Tab>`) to fuzzy-pick
      # files, dirs, hostnames, env vars, kill targets, etc.
      source ${pkgs.fzf}/share/fzf/completion.zsh

      # ── fzf-tab ──────────────────────────────────────────
      # Replaces the default tab-completion menu with an fzf overlay.
      source ${pkgs.zsh-fzf-tab}/share/fzf-tab/fzf-tab.plugin.zsh

      # ── zsh-history-substring-search ─────────────────────
      # Type any prefix (e.g. `git`) then ↑/↓ to walk only history entries
      # that contain that substring. Bindings live in zvm_after_init below.
      source ${pkgs.zsh-history-substring-search}/share/zsh-history-substring-search/zsh-history-substring-search.zsh

      # zsh-vi-mode rebuilds viins/vicmd keymaps on first prompt, wiping every
      # bindkey set before it (including fzf's Ctrl-R / Ctrl-T / Alt-C and the
      # history-substring-search arrow keys). Re-install everything here.
      function zvm_after_init() {
        # Re-source fzf so its widgets get re-bound in the fresh keymap.
        source ${pkgs.fzf}/share/fzf/key-bindings.zsh

        # history-substring-search: bind BOTH escape sequences for ↑/↓.
        # CSI form (^[[A/B) is sent in normal mode; SS3 form (^[OA/B) is sent
        # when ZLE puts the terminal in application keypad mode — both happen
        # depending on terminal state.
        bindkey '^[[A' history-substring-search-up
        bindkey '^[[B' history-substring-search-down
        bindkey '^[OA' history-substring-search-up
        bindkey '^[OB' history-substring-search-down
        # Vi-cmd-mode (after Esc): k/j walk history with the same prefix match.
        bindkey -M vicmd 'k' history-substring-search-up
        bindkey -M vicmd 'j' history-substring-search-down
      }

      # ── Completion styling ───────────────────────────────
      zstyle ':completion:*' matcher-list "" "m:{a-zA-Z}={A-Za-z}" "r:|=*" "l:|=* r:|=*"
      zstyle ':completion:*' menu select
      zstyle ':completion:*' file-sort access
      zstyle ':completion:*:default' list-colors ''${(s.:.)LS_COLORS}
      zstyle ':completion:*' use-cache on
      zstyle ':completion:*' cache-path "${home}/.zcompcache"

      # ── Zoxide (smarter cd) ──────────────────────────────
      # Tracks dirs you visit; `cd <partial>` jumps to the highest-ranked
      # match. `cd /absolute/path` still behaves like normal cd.
      eval "$(zoxide init --cmd cd zsh)"

      # ── Custom shell functions ───────────────────────────
      source ${home}/.config/zsh/common.zsh

      if [ -f "$HOME/.zsh_secrets" ]; then
        source "$HOME/.zsh_secrets"
      fi

      export PATH="${home}/.npm-global/bin:$PATH"
      
      # ── Ghostty terminal integration ─────────────────────
      if [[ -n $GHOSTTY_RESOURCES_DIR ]]; then
          typeset -g GHOSTTY_LAST_PWD_FILE="''${XDG_STATE_HOME:-$HOME/.local/state}/ghostty/last-pwd"

          if [[ $PWD == $HOME && -r $GHOSTTY_LAST_PWD_FILE ]]; then
            IFS= read -r ghostty_last_pwd < "$GHOSTTY_LAST_PWD_FILE"
            [[ -d $ghostty_last_pwd ]] && builtin cd -- "$ghostty_last_pwd"
            unset ghostty_last_pwd
          fi

          function ghostty-save-pwd() {
            local state_dir="''${GHOSTTY_LAST_PWD_FILE:h}"
            local pending_file="$GHOSTTY_LAST_PWD_FILE.$$"

            mkdir -p -- "$state_dir"
            print -r -- "$PWD" > "$pending_file"
            mv -f -- "$pending_file" "$GHOSTTY_LAST_PWD_FILE"
          }

          autoload -Uz add-zsh-hook
          add-zsh-hook chpwd ghostty-save-pwd
          ghostty-save-pwd

          source "$GHOSTTY_RESOURCES_DIR"/shell-integration/zsh/ghostty-integration
      fi

      # ── VS Code terminal integration ─────────────────────
      [[ "$TERM_PROGRAM" == "vscode" ]] && . "$(code --locate-shell-integration-path zsh)"
    '';
  };
}
