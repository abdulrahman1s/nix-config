# ── Shell Functions ──────────────────────────────────

# Cheat-sheet lookup: `what tar extract`
what() {
  curl -s "cheat.sh/$(printf '%s' "$*" | tr ' ' '+')"
}

# Cloudflare quick tunnel: `tunnel 3000`
tunnel() {
  if [[ -z "$1" ]]; then
    echo "Usage: tunnel <port>"
    return 1
  fi
  cloudflared tunnel --url "http://localhost:$1" \
    2> >(grep -oE 'https://.*trycloudflare\.com')
}

# Commit with a random message (pick one of five via fzf) & push
commit() {
  local -a msgs
  local i msg choice
  for i in {1..5}; do
    msg=$(curl -sk https://whatthecommit.com/index.txt) || continue
    [[ -n "$msg" ]] && msgs+=("$msg")
  done
  if (( ${#msgs} == 0 )); then
    echo "commit: failed to fetch commit messages" >&2
    return 1
  fi
  choice=$(printf '%s\n' "${msgs[@]}" \
           | fzf --no-sort --reverse --height=40% --prompt='commit ❯ ') || return
  git commit -m "$choice" && git push
}

# Universal archive extractor
ex() {
  if (( $# == 0 )); then
    echo "Usage: ex <file>..." >&2
    return 1
  fi
  local f lower rc=0
  for f in "$@"; do
    if [[ ! -f "$f" ]]; then
      echo "'$f' is not a valid file" >&2
      rc=1
      continue
    fi
    lower="${(L)f}"
    case "$lower" in
      *.tar.bz2|*.tbz2) tar xjf "$f"    ;;
      *.tar.gz|*.tgz)   tar xzf "$f"    ;;
      *.tar.xz|*.txz)   tar xJf "$f"    ;;
      *.tar.zst|*.tzst) tar --zstd -xf "$f" ;;
      *.tar.lz)         tar --lzip -xf "$f" ;;
      *.tar.lzma)       tar --lzma -xf "$f" ;;
      *.tar)            tar xf "$f"     ;;
      *.zip|*.jar|*.war) unzip "$f"     ;;
      *.rar)            unrar x "$f"    ;;
      *.7z)             7z x "$f"       ;;
      *.7z.[0-9]*)      7z x "${f%.[0-9]*}.001" ;;
      *.bz2)            bunzip2 "$f"    ;;
      *.gz)             gunzip "$f"     ;;
      *.xz)             unxz "$f"       ;;
      *.zst)            unzstd "$f"     ;;
      *.lzma)           unlzma "$f"     ;;
      *.lz4)            lz4 -d "$f"     ;;
      *.z)              uncompress "$f" ;;
      *) echo "'$f' cannot be extracted via ex()" >&2; rc=1 ;;
    esac
  done
  return $rc
}

# VRAM usage per process
vram() {
  nvidia-smi --query-gpu=gpu_name,memory.used,memory.total --format=csv,noheader 2>/dev/null | \
    awk -F', ' '{
      used=$2+0; total=$3+0; pct=used/total*100
      bar=""; filled=int(pct/5)
      for(i=0;i<filled;i++) bar=bar"█"
      for(i=filled;i<20;i++) bar=bar"░"
      printf "\n\033[1m%s\033[0m  %s  %d / %d MiB (%.0f%%)\n\n", $1, bar, used, total, pct
    }'
  printf "\033[1;37m%-7s  %-20s  %8s\033[0m\n" "PID" "PROCESS" "VRAM"
  printf '%.0s─' {1..40}; echo
  nvidia-smi | awk '/Processes:/,0' | \
    grep '|.*MiB' | grep -v '+=\|+-' | \
    sed 's/^|//;s/|$//' | \
    awk '{
      pid=$4; mem=$(NF); sub(/MiB/,"",mem)
      cmd="tr \"\\0\" \" \" </proc/"pid"/cmdline 2>/dev/null"
      cmd | getline cl; close(cmd)
      name=cl; sub(/ .*/, "", name); sub(/.*\//, "", name)
      printf "%5d MiB  %-7s  %s\n", mem+0, pid, name
    }' | sort -rn | awk '{printf "%-7s  %-20s  %5d MiB\n", $3, $4, $1}'
}

# Journal logs for a service (user or system)
logs() {
  if [[ -z "$1" ]]; then
    echo "Usage: logs <service> [--user|--system]"
    return 1
  fi
  local unit="$1"
  local scope="${2:---user}"
  if [[ "$scope" == "--user" ]]; then
    journalctl --user-unit="$unit" -b -f --no-hostname
  else
    journalctl -u "$unit" -b -f --no-hostname
  fi
}

# Upload a file via ffsend and copy the share URL to the clipboard
upload() {
  local out url
  out=$(ffsend upload --host https://send.vis.ee/ "$@") || return $?
  echo "$out"
  url=$(printf '%s' "$out" | grep -oE 'https?://send\.vis\.ee/[^[:space:]]+' | tail -1)
  if [[ -n "$url" ]]; then
    printf '%s' "$url" | copy
    echo "URL copied to clipboard"
  fi
}

# Shorten a URL via is.gd & copy the result to clipboard.
# `shorten https://example.com/long`  or bare `shorten` (uses clipboard).
shorten() {
  local url="$1" short
  if [[ -z "$url" ]]; then
    url=$(paste)
    [[ "$url" != http* ]] && url=""
  fi
  if [[ -z "$url" ]]; then
    echo "Usage: shorten <url>  (or copy a URL to clipboard first)" >&2
    return 1
  fi
  short=$(curl -sS --get --data-urlencode "url=$url" \
    'https://v.gd/create.php?format=simple') || return 1
  if [[ "$short" != http* ]]; then
    echo "shorten: $short" >&2
    return 1
  fi
  printf '%s' "$short" | copy
  echo "$short"
}

# Copy to clipboard.
#   copy <file>        → file:// URI, staged under ~/Downloads when needed
#   cmd | copy          → stdin as text
copy() {
  if [[ -z "$1" ]]; then
    local stage_dir="$HOME/Downloads/.copy-stage"
    mkdir -p "$stage_dir" || return 1
    find "$stage_dir" -mindepth 1 -delete 2>/dev/null || return 1

    if [[ -n "$WAYLAND_DISPLAY" ]] && command -v wl-copy &>/dev/null; then
      wl-copy
    elif command -v xclip &>/dev/null; then
      xclip -selection clipboard
    elif command -v xsel &>/dev/null; then
      xsel --clipboard --input
    else
      echo "copy: no clipboard tool found (need wl-copy, xclip, or xsel)" >&2
      return 1
    fi
    return
  fi

  if [[ ! -f "$1" ]]; then
    echo "copy: '$1' is not a file" >&2
    return 1
  fi

  local abs_path base downloads stage_dir sanitized staged uri
  abs_path=$(realpath -- "$1") || return 1
  base="${abs_path:t}"
  downloads="$HOME/Downloads"
  stage_dir="$downloads/.copy-stage"
  sanitized=$(python3 -c 'import sys, unicodedata; print(unicodedata.normalize("NFKC", sys.argv[1]), end="")' "$base") || return 1

  local -a arabic_pairs=(
    "٠:0" "١:1" "٢:2" "٣:3" "٤:4" "٥:5" "٦:6" "٧:7" "٨:8" "٩:9"
    "۰:0" "۱:1" "۲:2" "۳:3" "۴:4" "۵:5" "۶:6" "۷:7" "۸:8" "۹:9"
    "ء:a" "آ:a" "أ:a" "إ:i" "ٱ:a" "ا:a"
    "ب:b" "ة:h" "ت:t" "ث:th" "ج:j" "ح:h" "خ:kh"
    "د:d" "ذ:dh" "ر:r" "ز:z" "س:s" "ش:sh"
    "ص:s" "ض:d" "ط:t" "ظ:z" "ع:a" "غ:gh"
    "ف:f" "ق:q" "ك:k" "گ:g" "ل:l" "م:m"
    "ن:n" "ه:h" "و:w" "ؤ:w" "ي:y" "ى:a" "ئ:y"
    "پ:p" "چ:ch" "ژ:zh" "ڤ:v"
    "ً:" "ٌ:" "ٍ:" "َ:" "ُ:" "ِ:" "ّ:" "ْ:" "ٰ:" "ـ:"
  )
  local pair from to
  for pair in "${arabic_pairs[@]}"; do
    from="${pair%%:*}"
    to="${pair#*:}"
    sanitized="${sanitized//$from/$to}"
  done

  sanitized=$(printf '%s' "$sanitized" | iconv -f UTF-8 -t ASCII//TRANSLIT//IGNORE 2>/dev/null \
              | tr -c 'A-Za-z0-9._-' '_' | tr -s '_' | sed 's/^[._-]*//; s/[._-]*$//')
  [[ -z "$sanitized" ]] && sanitized="file_$$"

  mkdir -p "$stage_dir" || return 1
  if [[ "$abs_path" == "$stage_dir"/* ]]; then
    find "$stage_dir" -mindepth 1 ! -samefile "$abs_path" -delete 2>/dev/null || return 1
  else
    find "$stage_dir" -mindepth 1 -delete 2>/dev/null || return 1
  fi

  # Brave's sandbox only sees ~/Downloads; stage files from outside it, or
  # files whose original name had non-ASCII bytes (Chromium nightly traps
  # on certain codepoints — e.g. U+FF5C from yt-dlp's `|` substitution).
  staged="$abs_path"
  if [[ "$base" != "$sanitized" ]] || [[ "$abs_path" != "$downloads"/* ]]; then
    staged="$stage_dir/$sanitized"
    ln -f -- "$abs_path" "$staged" 2>/dev/null \
      || cp --reflink=auto -f -- "$abs_path" "$staged" || return 1
  fi

  uri=$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).as_uri())' "$staged") || return 1
  if [[ -n "$WAYLAND_DISPLAY" ]] && command -v wl-copy &>/dev/null; then
    printf '%s\r\n' "$uri" | wl-copy --type text/uri-list && echo "Copied URI to clipboard: $staged"
  elif command -v xclip &>/dev/null; then
    printf '%s\r\n' "$uri" | xclip -selection clipboard -t text/uri-list && echo "Copied URI to clipboard: $staged"
  else
    echo "copy: no clipboard tool found (need wl-copy or xclip)" >&2
    return 1
  fi
}

# Paste clipboard contents to stdout. Wayland + X11. Note: shadows the
# coreutils `paste` builtin; use `command paste` for the original.
paste() {
  if [[ -n "$WAYLAND_DISPLAY" ]] && command -v wl-paste &>/dev/null; then
    wl-paste 2>/dev/null
  elif command -v xclip &>/dev/null; then
    xclip -selection clipboard -o 2>/dev/null
  elif command -v xsel &>/dev/null; then
    xsel --clipboard --output 2>/dev/null
  else
    return 1
  fi
}

# Create a secret GitHub gist from files, args, stdin, or clipboard contents.
gist() {
  local filename tmp url rc arg all_files=1
  if (( $# > 0 )); then
    for arg in "$@"; do
      if [[ ! -f "$arg" || ! -r "$arg" ]]; then
        all_files=0
        break
      fi
    done
    if (( all_files )); then
      if (( $# == 1 )); then
        url=$(gh gist create --filename "${1:t}" - < "$1") || return $?
      else
        url=$(gh gist create "$@") || return $?
      fi
      printf '%s' "$url" | copy
      echo "$url"
      return
    fi
  fi

  if [[ -t 0 ]]; then
    printf "File name: " >&2
    IFS= read -r filename
  elif { : < /dev/tty } 2>/dev/null; then
    printf "File name: " > /dev/tty
    IFS= read -r filename < /dev/tty
  else
    echo "gist: cannot prompt for filename without a terminal" >&2
    return 1
  fi
  if [[ -z "$filename" ]]; then
    echo "gist: filename required" >&2
    return 1
  fi

  tmp="$(mktemp)" || return 1
  if (( $# > 0 )); then
    printf '%s\n' "$*" > "$tmp"
  elif [[ -t 0 ]]; then
    paste > "$tmp" || {
      rc=$?
      rm -f "$tmp"
      echo "gist: clipboard unavailable" >&2
      return $rc
    }
  else
    cat > "$tmp" || {
      rc=$?
      rm -f "$tmp"
      echo "gist: stdin unavailable" >&2
      return $rc
    }
  fi
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    echo "gist: input is empty" >&2
    return 1
  fi

  url=$(gh gist create --filename "$filename" - < "$tmp") || {
    rc=$?
    rm -f "$tmp"
    return $rc
  }
  rm -f "$tmp"
  printf '%s' "$url" | copy
  echo "$url"
}



# Download as mp3 & copy to clipboard.
# `mp3 <url>...`  or bare `mp3` (uses clipboard).
mp3() {
  local -a urls
  if (( $# == 0 )); then
    local clip
    clip=$(paste)
    if [[ "$clip" != http* ]]; then
      echo "Usage: mp3 <url>...  (or copy a URL to clipboard first)" >&2
      return 1
    fi
    urls=("$clip")
  else
    urls=("$@")
  fi
  local tmp="$(mktemp -d)"
  yt-dlp -x --audio-format mp3 --restrict-filenames --quiet --progress \
    --progress-template "download:[%(progress._percent_str)s] %(progress._speed_str)s ETA: %(progress._eta_str)s" \
    -o "$tmp/%(title)s.%(ext)s" "${urls[@]}" || { rm -rf "$tmp"; return 1; }
  local f
  for f in "$tmp"/*.mp3; do
    mv "$f" .
    copy "$(basename "$f")"
  done
  rm -rf "$tmp"
}

# Download as mp4 & copy to clipboard (default 720p).
# `mp4 <url> [quality]`  or bare `mp4 [quality]` (uses clipboard).
# Quality: 1080 / 2k / 4k / fhd / hd / sd, etc.
mp4() {
  local url="$1" q
  if [[ "$url" == http* ]]; then
    # `mp4 <url> [quality]` — quality is $2 if given.
    q="${2:-720}"
  else
    # $1 is not a URL — try clipboard. If $1 was something else (e.g.
    # `mp4 1080`), treat it as the quality token; otherwise default.
    local clip
    clip=$(paste)
    if [[ "$clip" != http* ]]; then
      echo "Usage: mp4 <url> [quality]  (or copy a URL to clipboard first)" >&2
      return 1
    fi
    url="$clip"
    q="${1:-720}"
  fi
  q="${q%[pP]}"
  case "$q" in
    2k|2K) q=1440 ;;
    4k|4K) q=2160 ;;
    fhd|FHD) q=1080 ;;
    hd|HD) q=720 ;;
    sd|SD) q=480 ;;
  esac
  local quality="$q"
  local tmp="$(mktemp -d)"
  echo "Selected: ${quality}p"
  local info size
  info=$(yt-dlp -f "bestvideo[height<=$quality]+bestaudio/best[height<=$quality]" \
    --print "%(resolution)s %(format_id)s %(vcodec)s/%(acodec)s %(filesize_approx|0)s" \
    "$url" 2>/dev/null)
  size="${info##* }"
  if [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 ]]; then
    if (( size >= 1000000000 )); then size=$(printf "%.1f GB" $((size / 1000000000.0)))
    elif (( size >= 1000000 )); then size=$(printf "%.1f MB" $((size / 1000000.0)))
    elif (( size >= 1000 )); then size=$(printf "%.1f KB" $((size / 1000.0)))
    else size="${size} B"; fi
  else size="Unknown"; fi
  local res="${info%% *}"
  local rest="${info#* }"
  local fmt="${rest%% *}"
  local codec="${rest#* }"
  codec="${codec% *}"
  printf "  \033[1;37mResolution:\033[0m %s\n" "$res"
  printf "  \033[1;37mFormat:\033[0m     %s\n" "$fmt"
  printf "  \033[1;37mCodec:\033[0m      %s\n" "$codec"
  printf "  \033[1;37mSize:\033[0m       \033[1;33m%s\033[0m\n" "$size"
  yt-dlp -f "bestvideo[height<=$quality]+bestaudio/best[height<=$quality]" \
    --merge-output-format mp4 --restrict-filenames --quiet --progress \
    --progress-template "download:[%(progress._percent_str)s] %(progress._speed_str)s ETA: %(progress._eta_str)s" \
    -o "$tmp/%(title)s [%(resolution)s].%(ext)s" "$url" || { rm -rf "$tmp"; return 1; }
  local f
  for f in "$tmp"/*.mp4; do
    mv "$f" .
    copy "$(basename "$f")"
  done
  rm -rf "$tmp"
}

# Fuzzy history search as a command (same UX as Ctrl-R, runnable by name).
# Optional arg = initial fzf query: `history docker` opens prefiltered.
# Selected line lands on the prompt buffer, ready to edit or run.
# Shadows the `history` builtin — use `fc -l` if you need the raw list.
history() {
  local cmd
  cmd=$(fc -rl 1 \
        | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//' \
        | awk '!seen[$0]++' \
        | fzf --no-sort --reverse --height=40% --tiebreak=index \
              --query="$*" --prompt='search ❯ ') || return
  print -z -- "$cmd"
}


myip() {
  local addr
  addr="$(curl -s http://ipecho.net/plain)"
  printf '%s' "$addr" | copy
  echo "$addr"
}

mylocalip() {
  local addr
  addr="$(hostname -I | awk '{print $1}')"
  printf '%s' "$addr" | copy
  echo "$addr"
}

# Screen record via gpu-screen-recorder. Picks a source via the portal.
# `record`     → fzf prompts for container / codec / quality / fps / audio.
# `record -d`  → run straight with defaults (mp4 h264 high 30, no audio).
# In each fzf prompt the default is the top entry — just hit Enter to keep it.
record() {
  local quality codec fps container audio out
  local -a audio_args codec_opts
  if [[ "$1" == "-d" || "$1" == "--default" ]]; then
    container=mp4 codec=h264 quality=high fps=30 audio=none
  else
    container=$(printf '%s\n' 'mp4 (default)' mkv webm flv \
                | fzf --prompt='container ❯ ' --height=40% --reverse) || return
    container=${container%% *}

    # Codec list is constrained by container — gpu-screen-recorder bails at
    # runtime if the pair is invalid (e.g. vp9 in mp4, h264 in webm).
    case "$container" in
      mp4)  codec_opts=('h264 (default)' hevc av1) ;;
      mkv)  codec_opts=('h264 (default)' hevc av1 vp8 vp9) ;;
      webm) codec_opts=('vp8 (default)' vp9 av1) ;;
      flv)  codec_opts=('h264 (default)') ;;
    esac
    codec=$(printf '%s\n' "${codec_opts[@]}" \
            | fzf --prompt='codec ❯ ' --height=40% --reverse) || return
    codec=${codec%% *}

    quality=$(printf '%s\n' 'high (default)' medium very_high ultra \
              | fzf --prompt='quality ❯ ' --height=40% --reverse) || return
    quality=${quality%% *}

    fps=$(printf '%s\n' '30 (default)' 60 90 120 144 240 \
          | fzf --prompt='fps ❯ ' --height=40% --reverse) || return
    fps=${fps%% *}

    audio=$(printf '%s\n' 'none (default)' system mic 'system+mic' \
            | fzf --prompt='audio ❯ ' --height=40% --reverse) || return
    audio=${audio%% *}
  fi

  case "$audio" in
    system)     audio_args=(-a default_output) ;;
    mic)        audio_args=(-a default_input) ;;
    system+mic) audio_args=(-a default_output -a default_input) ;;
  esac

  mkdir -p "$HOME/Videos"
  out="$HOME/Videos/$(date +%F-%H%M%S).${container}"
  printf "  \033[1;37mContainer:\033[0m %s\n" "$container"
  printf "  \033[1;37mCodec:\033[0m     %s\n" "$codec"
  printf "  \033[1;37mQuality:\033[0m   %s\n" "$quality"
  printf "  \033[1;37mFPS:\033[0m       %s\n" "$fps"
  printf "  \033[1;37mAudio:\033[0m     %s\n" "$audio"
  printf "  \033[1;37mOutput:\033[0m    \033[1;33m%s\033[0m\n" "$out"
  gpu-screen-recorder -w portal -f "$fps" -k "$codec" -q "$quality" \
    -c "$container" "${audio_args[@]}" -o "$out"
  [[ -f "$out" ]] && copy "$out"
}

# Copy file with a progress bar
cpp() {
    set -e
    strace -q -ewrite cp -- "${1}" "${2}" 2>&1 |
    awk '{
        count += $NF
        if (count % 10 == 0) {
            percent = count / total_size * 100
            printf "%3d%% [", percent
            for (i=0;i<=percent;i++)
                printf "="
            printf ">"
            for (i=percent;i<100;i++)
                printf " "
            printf "]\r"
        }
    }
    END { print "" }' total_size="$(stat -c '%s' "${1}")" count=0
}
