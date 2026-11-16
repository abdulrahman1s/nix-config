---
name: computer-use
description: Use the user's live desktop (niri on Wayland). Screenshot a window, monitor or region; read or set the clipboard; list, focus and arrange windows; type keys into an app; OCR the screen; send notifications; open files and URLs; record the screen. Hand web interaction to the browser-use skill.
---

# Computer use

This is the user's daily-driver desktop: the **niri** Wayland compositor with
the noctalia shell. There is no X11 desktop, so `xdotool`, `xclip`, `scrot`
and `import` do not work. Use the tools below.

Everything here touches the user's real session. Prefer reading (screenshots,
window lists) over acting. Before typing into a window, closing one or
changing focus while the user may be working, say what you are about to do.

## Windows and monitors

```bash
niri msg -j windows          # id, app_id, title, workspace_id, is_focused, pid
niri msg -j focused-window
niri msg -j workspaces       # id, idx, name, output, is_active
niri msg -j outputs          # monitors, modes, logical position and scale
niri msg -j focused-output
```

Find a window by app or title with `jq`, then act on its id:

```bash
id=$(niri msg -j windows | jq -r '.[] | select(.app_id=="brave-origin") | .id' | head -n1)
niri msg action focus-window --id "$id"
niri msg action close-window --id "$id"          # ask first
niri msg action move-window-to-workspace --window-id "$id" 3
niri msg action spawn -- ghostty                 # launch detached from your shell
```

Run `niri msg action --help` and `niri msg action <name> --help` for the full
list. Do not use `niri msg pick-window` or `pick-color`; they wait for a mouse
click from the user.

## Screenshots

Use the bundled helper, `scripts/shot` in this skill's directory. It prints
the saved PNG path.

```bash
shot=~/.claude/skills/computer-use/scripts/shot   # or ~/.agents/skills/...
$shot window                     # focused window
$shot window 142 /tmp/x.png      # by niri id; works on other workspaces too
$shot output                     # focused monitor (grim)
$shot output DP-2
$shot all                        # every monitor
$shot region 1477,0 800x600      # logical global coordinates, see outputs
```

- Prefer `window <id>` over a full-screen capture. It captures only that
  window, even when it is on another workspace or covered.
- niri's own screenshot actions always overwrite the clipboard. The helper
  saves and restores it; never call `niri msg action screenshot*` directly.
- Captures are full resolution (a 2x-scaled monitor gives ~3800px wide
  images). Downscale before viewing to save context:
  `magick in.png -resize 1600x out.png`. Crop with `-crop WxH+X+Y`.
- Write screenshots to your scratch or temp directory, not the repository.

## Reading text from the screen

When you need the text rather than the picture, OCR it (English and Arabic
data are installed):

```bash
tesseract shot.png - -l eng          # or -l eng+ara
```

For a browser page, get the DOM text through browser-use instead; it is exact.

## Clipboard

```bash
wl-paste --list-types                # what is offered
wl-paste -n                          # text, no trailing newline
wl-paste -t image/png > clip.png     # an image
printf %s "text" | wl-copy           # set text
wl-copy -t image/png < img.png       # set an image
```

- Setting the clipboard replaces what the user copied. Do it only when asked
  or when it is the point of the task, and say so.
- `cliphist list` / `cliphist decode <id>` read the clipboard history. It can
  hold passwords and private messages: read it only when the user asks you to
  find something they copied earlier.
- To hand the user a file that will be pasted into Brave, use the zsh `copy`
  function from `config/zsh/common.zsh`, not raw `wl-copy` of a `file://` URI;
  it works around a Brave crash with non-ASCII file names.

## Keyboard input

`wtype` sends keys to the **focused** window through the virtual-keyboard
protocol. Focus the target first and confirm with `niri msg -j focused-window`
right before typing; otherwise the keys land in whatever has focus, often the
user's terminal.

```bash
niri msg action focus-window --id "$id"
wtype 'hello world'
wtype -k Return
wtype -M ctrl -k l -m ctrl           # Ctrl+L
wtype -M ctrl -M shift -k t -m shift -m ctrl
```

Never type secrets with `wtype`.

There is **no pointer tool** (no ydotool, dotool or wlrctl), so you cannot
click or move the mouse. For web pages, use browser-use. For other apps, use
keyboard shortcuts, the app's CLI or D-Bus interface, or ask the user to click.

## Browser

For anything inside a web page (navigate, click, fill forms, read the DOM,
screenshot a page, use the user's logged-in sessions), load the
**browser-use** skill and drive the browser through `browser-use`. The user's
browser is Brave Origin (`app_id` `brave-origin`), running in a NixPak sandbox.
Run `browser-use doctor` if it cannot connect.

A plain public page or API needs no browser: fetch it with `curl` or your
fetch tool. To just show the user a page, `xdg-open https://...`.

## Opening things and notifying

```bash
xdg-open ~/Downloads/report.pdf      # default app for a file or URL
notify-send 'Agent' 'Build finished' # desktop notification
notify-send -u critical 'Agent' 'Needs your input'
```

A notification is a good way to get the user's attention when a long task
finishes or you are blocked on them.

## Screen recording

`gpu-screen-recorder` records on the GPU. Run it in the background and stop
it with SIGINT so the file is finalized:

```bash
gpu-screen-recorder -w DP-2 -f 30 -o /tmp/rec.mp4 &   # a monitor; or -w focused
pid=$!
# ... do the thing ...
kill -INT "$pid"; wait "$pid"
```

Get monitor names from `gpu-screen-recorder --list-monitors`. Record only
when the user asked for it.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `niri msg` fails: no socket | `NIRI_SOCKET` is unset in your environment. Find it with `ls /run/user/$UID/niri.*.sock` and export it. |
| `wl-paste`, `grim` or `wtype` fail: no display | Export `WAYLAND_DISPLAY` (usually `wayland-1`; see `ls /run/user/$UID/wayland-*`). |
| Black or empty window capture | The window may be minimized to a tray or not yet mapped; check `niri msg -j windows`. |
| Clipboard came back empty after a screenshot | The previous owner offered no readable type; tell the user. |
