{ inputs, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # ── Editors ────────────────────────────────────────────
    neovim # Modern, highly extensible Vim fork

    # ── Terminal & Shell ───────────────────────────────────
    eza # Modern replacement for 'ls'
    fastfetch # Prints system info and logo to the terminal
    ghostty # Fast, modern terminal emulator
    pure-prompt # Minimal, fast Zsh prompt
    zoxide # Smarter 'cd' command that learns your habits
    zsh-vi-mode # Vim keybindings for Zsh

    # ── Archives & Compression ─────────────────────────────
    bzip2 # Compressor for .bz2 files
    gnutar # Creates and extracts .tar archives
    gzip # Compressor for .gz files
    p7zip # Archiver for .7z, .zip, and more
    unrar # Extracts .rar archives
    unzip # Extracts .zip archives
    xz # Compressor for .xz files

    # ── Networking ─────────────────────────────────────────
    aria2 # Fast CLI download manager
    cloudflared # CLI for Cloudflare Tunnels
    curl # Downloads data from URLs
    dig # DNS lookup utility
    ffsend # Securely share files from the CLI
    ngrep # Grep, but for live network traffic
    tcpdump # Captures and analyzes network traffic
    # tshark               # Terminal version of Wireshark
    wget # Downloads files from the web
    # wireshark            # GUI for analyzing network traffic
    xh # Friendly tool for sending HTTP requests (curl alternative)

    # ── Development ────────────────────────────────────────
    binutils # Essential tools for compiled binaries (ld, objdump, strings)
    gh # Official GitHub CLI
    jq # JSON processor used by niri helper scripts
    jnv # Interactive JSON filter using jq
    inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default # Edits age-encrypted secrets

    # ── Media ──────────────────────────────────────────────
    ffmpeg-headless # CLI transcoding without ffmpeg-full's duplicate desktop stack
    yt-dlp # Downloads videos from YouTube and other sites

    # ── System Utilities ───────────────────────────────────
    bat # Better 'cat' with syntax highlighting
    btop # Beautiful CLI system resource monitor
    fd # Faster, user-friendly alternative to 'find'
    file # Determines file types from their content
    htop # Interactive process viewer (better 'top')
    lm_sensors # Reads CPU and hardware temperatures
    lsof # Lists open files and the processes using them
    psmisc # Process management tools (killall, pstree)
    ripgrep # Extremely fast text searcher (better 'grep')
    tree # Lists directories in a visual tree format
    usbutils # USB device tools (provides 'lsusb')
    pciutils # PCI device tools (provides 'lspci')

    # ── Miscellaneous & Fun ────────────────────────────────
    blobdrop # Drag-and-drop files directly from the terminal
    cmatrix # Falling green code from The Matrix

    fzf
    zsh-fzf-tab

    witr # Command-line tool to find out why processes are running
    vhs # Terminal-recording

    libnotify
  ];
}
