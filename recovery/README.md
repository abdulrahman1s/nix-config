# NixOS recovery disk

A small NixOS system on the WD Green SN350 for repairing the main installation.
It has its own EFI partition and Limine bootloader, so it still boots when the
Samsung 990 Pro, its EFI partition or the main system is broken.

**Using it:** the guide for when something is wrong is
[`docs/guide.html`](docs/guide.html). On the recovery it opens from **Recovery
Guide** in the dock. [`docs/readme.txt`](docs/readme.txt) (`~/readme.txt` there)
is a cheat sheet of every shell tool, with example commands and the disk map.

## Files

| Path | What it holds |
| --- | --- |
| `configuration.nix` | Entry point: boot entries, graphics, users, services |
| `tools.nix` | The repair commands and the command-line toolbox |
| `desktop.nix` | labwc, Noctalia, the desktop menu and the dock entries |
| `shell.nix` | zsh, Ghostty, Claude Code and Codex, taken from the main system |
| `vm.nix` | The QEMU test VM |
| `disko.nix` | SN350 partition layout |
| `usb.nix` | Filesystems of the USB drive copy, used instead of `disko.nix` |
| `scripts/` | Commands installed on the recovery (`system-chroot`, `main-logs`, ...) |
| `apps/` | `nix run .#recovery-update`, `-usb`, `-partition` and `-vm`, run from the main system |
| `config/` | labwc, Noctalia and Foot settings |
| `docs/` | The guide, the cheat sheet and the assistants' instructions |

## What's on it

- **Desktop:** labwc with the labAdwaita-dark theme; Noctalia's bar and dock
  with a matching palette (`config/noctalia/labAdwaita-dark.json`) and GNOME's dark Adwaita
  wallpaper. Ly is the login screen, with the main system's Ly fixes.
  Everything works with the mouse:
  - the dock and the bar's launcher;
  - a menu on any click on the empty desktop;
  - title-bar buttons and the bar's taskbar.
- **Terminal:** the main system's zsh, read from its merged configuration
  (`shell.nix`): the same prompt, plugins, history settings, functions and
  aliases, including `claudex` and `codexx`. Ghostty uses the main system's
  config, with title bars kept for labwc.
- **Claude Code and Codex**, signed in with the main system's logins, which
  `recovery-update` copies. They're under **Assistants** in the desktop menu and
  launcher. Both load `docs/assistant-instructions.md` in every session, so
  they know they're on the recovery and how to work safely there. It is
  installed as Claude Code's managed `/etc/claude-code/CLAUDE.md`, and Codex's
  `~/.codex/AGENTS.md` links to it. The source isn't named `AGENTS.md`, because
  Codex would then apply it to sessions started in `recovery/` on the main
  system.
- **Displays:** at login, each monitor gets its native resolution at the highest
  refresh rate it offers, and a scale from that resolution (2× at 4K, 1.25× at
  1440p). See `scripts/recovery-displays.sh`.
- **Repair tools**, each with a dock and menu entry:

  | Entry | Command |
  | --- | --- |
  | Enter Main System | `sudo system-chroot` |
  | Repair Main Bootloader | `sudo system-chroot --reinstall-bootloader` |
  | Main System Logs | `sudo main-logs` |
  | Disk Health | `sudo disk-health` |
  | System Monitor | `btop` |

- **Boot menu entries:**
  - the recovery itself;
  - **safe-graphics**, without the NVIDIA driver, for a black screen;
  - **Memtest86+**, a RAM test.
- **Login:** the normal username with the main system's root password. Both
  accounts use the root password hash that `recovery-update` copies.

`system-chroot` reads the main system's disks, mount options and impermanence
binds from `nixosConfigurations.default`, so it follows
`hardware-configuration.nix` and `system/impermanence.nix` without copies.
`nixos-enter` then runs the main system's activation against that real
persisted state, just as a boot would. If the main initrd's rollback was
interrupted after deleting `root` or `home`, it offers to restore them from
their blank snapshots.

## Try changes in a VM

```bash
nix run .#recovery-vm
```

This boots the recovery configuration in QEMU at 1920×1080. Log in with your
username and the password `recovery`. The VM uses the safe-graphics drivers,
starts from an empty root filesystem every run, and has none of the real disks
attached. The repair tools therefore report that the main system is missing.
See `vm.nix`.

Claude Code and Codex start signed in. `apps/recovery-vm.sh` shares copies of
this system's logins with the VM through a private folder in
`$XDG_RUNTIME_DIR`, which is removed when QEMU exits. The copies leave out the
refresh tokens, so the VM can never use one up and sign this system out. The
VM's sign-ins last until the copied access tokens expire; the launcher prints
both times. Using Claude Code or Codex on this system renews them for the next
run.

## Install or update

```bash
nix run .#recovery-update
```

It asks for sudo, checks the SN350's partition types and labels, copies the
currently decrypted root password hash, and installs the system and its Limine
bootloader onto the SN350 only. Limine is installed at the removable-media path
and doesn't touch UEFI variables or the main disk's boot entry. Noctalia and the
labwc themes build locally, because CI caches only the main system.

It also copies the Claude Code and Codex logins into the recovery's home:
`~/.claude/.credentials.json`, the account part of `~/.claude.json`, and
`~/.codex/auth.json`. They are stored with mode 0600 and never pass through the
Nix store. These are copies of one sign-in. If a refresh on one system signs the
other out, sign in again there (`/login` in Claude Code, `codex login`) or rerun
`recovery-update`.

The main system's Limine menu has a **NixOS Recovery** entry that chainloads
the SN350. If the main disk's EFI partition is gone, choose the WD Green SN350
in the motherboard's one-time boot menu instead.

## Put it on a USB drive

```bash
nix run .#recovery-usb                     # lists the USB drives attached now
nix run .#recovery-usb -- /dev/sdX         # erases that drive and installs onto it
```

This installs the same recovery system on a USB drive of 16 GB or more, for
when the SN350 itself fails. It boots from any UEFI firmware's one-time boot
menu, and its boot entries are tagged `usb`. It is a full installation, not a
live image, so settings and files you change on it are kept.

- It writes only to drives connected over USB. It never erases a drive that
  holds a filesystem the main system mounts, such as the NV3 data drive in its
  USB enclosure, even when it is unmounted. It also refuses a partition, a
  drive with mounted partitions, and a drive under 12 GiB. You confirm by
  typing the drive's name, such as `sdb`. Then it asks for sudo. (It passes
  that answer on to itself as `--erase=sdb`, which skips the question.)
- It mounts by the labels `RECOVERY-USB` and `RECOVUSBEFI`, so it refuses
  while another drive carries them, such as an older recovery USB drive.
- It copies the root password hash, as `recovery-update` does. The Claude Code
  and Codex logins are left out unless you add `--with-logins`, because
  anyone who finds a lost drive could read them. Without them, sign in on the
  drive (`/login` in Claude Code, `codex login`).
- `/mnt/SN350` is mounted when the SN350 is attached.

Rerun the command to update the drive; it is erased and reinstalled each
time.

## One-time setup

### Partition the SN350

Layout, declared in `disko.nix`:

```text
1 GiB EFI (RECOVERYEFI) | 24 GiB NixOS Recovery (NIXOS-RECOVERY) | rest: data (SN350, /mnt/SN350)
```

This erases the SN350:

1. Back up anything on it.
2. Unmount the data partition:

   ```bash
   sudo fuser -vm /mnt/SN350
   sudo umount /mnt/SN350
   ```

3. From this repository, run:

   ```bash
   nix run .#recovery-partition -- --confirm-erase-sn350
   ```

The wrapper targets the immutable EUI link
`nvme-eui.e8238fa6bf530001001b448b4056230e`. Before Disko runs, it checks the
model `WD Green SN350 1TB` and serial `24301E803752`, and it refuses while any
SN350 partition is mounted. Afterwards:

1. Check the three labels with `lsblk -f`.
2. Run `recovery-update`.
3. Activate the main configuration. That adds the boot menu entry and mounts
   `/mnt/SN350` by label.

### Grow the main Btrfs partition

`sudo resize-990pro`, run from the recovery, grows the main Btrfs partition to
`RESIZE_TARGET_GIB` (500 GiB, in `tools.nix`). The space comes from the
start of the 990 Pro's ext4 data partition (`/mnt/990Pro`), which shrinks by
the same amount.

1. It shows the plan and asks you to type `RESIZE`.
2. If it stops for any reason, run it again to continue. Don't boot the main
   system in between.
3. Progress and a log are kept in `/var/lib/resize-990pro` on the recovery
   disk.

A power loss while `resize2fs` shrinks ext4 can damage that filesystem, so back
up `/mnt/990Pro` first. It has already been run: the partition is 500 GiB.
