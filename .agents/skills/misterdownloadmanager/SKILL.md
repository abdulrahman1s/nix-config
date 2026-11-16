---
name: misterdownloadmanager
description: Use Mister Download Manager (MDM) for large downloads (1 GiB or more), explicit requests to use MDM, or control of existing MDM downloads. Do not use for small files or routine fetches.
---

# Mister Download Manager

MDM is the desktop download manager. It runs as the `misterdownloadmanager`
systemd user service, in a NixPak sandbox, and waits in the tray.

## When to use MDM

Reserve MDM for files known or reasonably expected to be at least 1 GiB,
unless the user explicitly requests MDM. For a playlist or batch, consider
the total expected size. A video, torrent or archive is not automatically large.

Use ordinary tools such as `curl` or `wget` for smaller files, including
documents, images, scripts, metadata and small release assets. For small media,
use an appropriate tool such as `yt-dlp` directly.

When size is unclear, use available metadata or a lightweight header request
if useful; do not start MDM just to find the size. Unknown size alone is not
a reason to use MDM.

Requests to list, pause, resume, queue or remove existing MDM downloads still
use this skill regardless of file size.

## Where files can go

The sandbox can write only to:

- `~/Downloads`
- `/mnt/990Pro/Downloads`, `/mnt/SN350/Downloads`, `/mnt/SN770/Downloads`,
  `/mnt/NV3/Downloads` (one per disk, present while that disk is mounted)

Pick one of these, or a subfolder of one, for every `folder` or `-o` value.
Any other path fails inside the sandbox. Do not work around this; tell the user.

## Prefer the MCP tools

When the `misterdownloadmanager` MCP server is connected, use its tools:

| Tool | Arguments |
| --- | --- |
| `list_downloads` | `status` (Queued, Downloading, Stopped, Complete, Error), `search`, `limit` |
| `add_download` | `url` (http, https, ftp, ftps or magnet), `folder`, `file_name`, `later` (queue without starting) |
| `pause_downloads` | `ids` |
| `resume_downloads` | `ids` |
| `remove_downloads` | `ids`, `delete_files` (default false keeps the files) |
| `start_queue` | none |

- Get ids from `list_downloads` before pausing, resuming or removing.
- Set `delete_files` only when the user asked to delete the files.
- A running download must be paused before it can be removed.
- A magnet link opens MDM's **Add torrent** window; the user picks the files there.

If the server is missing, register its stable launcher:

```bash
claude mcp add --scope user misterdownloadmanager -- ~/.local/bin/misterdownloadmanager-mcp
```

For Codex, `~/.codex/config.toml` takes:

```toml
[mcp_servers.misterdownloadmanager]
command = "/home/<user>/.local/bin/misterdownloadmanager-mcp"
```

## When a tool fails

| Error | Action |
| --- | --- |
| MDM isn't running | `systemctl --user start misterdownloadmanager.service`, then retry. |
| The automation API is off | Listing and control need it; adding works without it. Ask the user before turning it on: it lets agents read every download's name, address and folder. Then run `misterdownloadmanager-cli api on` once (it persists). |
| MDM didn't answer in time | A window in MDM is waiting for the user (a question, **Add torrent**). Ask them to answer it. |
| MDM refused the request | The IPC file is from an earlier start. Ask the user to restart MDM. |

## Command line fallback

`misterdownloadmanager-cli` runs in the same sandbox. Add `--json` for
machine-readable output.

```bash
misterdownloadmanager-cli --json status              # the app's list (needs the automation API)
misterdownloadmanager-cli pause 12 13                 # by id; also start, remove, delete
misterdownloadmanager-cli api on                      # turn the automation API on (ask first)
```

These commands download by themselves, without the app; their downloads do not
appear in MDM's list:

```bash
misterdownloadmanager-cli --json get <url> -o ~/Downloads
misterdownloadmanager-cli --json video-info <page-url>
misterdownloadmanager-cli --json video-get <page-url> -o ~/Downloads
misterdownloadmanager-cli --json torrent-info <magnet-or-file>
misterdownloadmanager-cli --json torrent-get <magnet-or-file> -o ~/Downloads
```

Run `misterdownloadmanager-cli <command> --help` for each command's options.
yt-dlp, ffmpeg and gallery-dl come from Nix; never run the `install-ytdlp`,
`install-ffmpeg` or `install-gallery-dl` commands. They fetch FHS builds that
do not run on NixOS.

Prefer adding downloads to the app (`add_download`) so the user sees them,
unless the user asked for a headless download.
