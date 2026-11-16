# NixOS recovery system

You are running on the **recovery system**, not the user's normal computer
setup. It is a small NixOS installation on the WD Green SN350, or the same
system on a USB drive: in `lsblk -f`, `/` is on the partition labelled
`NIXOS-RECOVERY` (SN350) or `RECOVERY-USB` (USB drive). Its only job is to
diagnose and repair the **main NixOS installation** on the Samsung 990 Pro,
which may be broken or unbootable right now. Assume nothing about the main
system's state until you have checked it.

## Where things are

- **This recovery system** is built from `recovery/` in the main system's
  repository and installed from the main system with
  `nix run .#recovery-update`.
  - Don't change it by hand or with `nixos-rebuild`. The next update replaces
    those changes.
  - For a missing tool, use `nix shell nixpkgs#<tool>`, which needs network.
- **The main system** is NixOS with impermanence.
  - Btrfs: `/dev/disk/by-uuid/ddb4bdb8-c522-4420-ba2d-ace00fc2054b`, with the
    subvolumes `root`, `home`, `nix`, `persist`, `root-blank` and `home-blank`.
  - `root` and `home` are reset from the blanks on every main boot; anything
    that survives lives under `/persist`.
  - EFI partition: `/dev/disk/by-uuid/FE76-C46F` (Limine).
  - Its flake repository is `/persist/home/abdulrahman/system-conf`, which
    appears as `/home/abdulrahman/system-conf` inside the chroot. That
    repository has its own `AGENTS.md`; follow it for any edit there.
  - That file asks for an `rtk` prefix on every shell command. `rtk` exists
    only inside the chroot; on the recovery itself, run commands without it.
- **Other disks:** run `lsblk -f`. `~/readme.txt` has the disk map and every
  tool, with examples.
- **Space for rescued data:** `/mnt/SN350`, the SN350's data partition. On
  the USB drive it is only there when the SN350 is attached; check with
  `findmnt /mnt/SN350`.

## Tools

These need root. You cannot type the sudo password, so ask the user to run them
in a terminal and share the output. Commands that print a lot can be saved to a
file, for example `sudo disk-health > ~/disk-health.txt 2>&1`, and then read.

| Command | What it does |
| --- | --- |
| `sudo main-logs` | Warnings and errors from the main system's last boot; read-only |
| `sudo disk-health` | `lsblk` overview and SMART health of every drive; read-only |
| `sudo system-chroot` | Root shell inside the main system (see below); not read-only |
| `sudo system-chroot --reinstall-bootloader` | Reinstall Limine and its menu on the main EFI partition |

`system-chroot` mounts the main system and recreates its impermanence bind
mounts. `nixos-enter` then runs the main system's activation against its real
persisted state, as a boot would.

For a read-only look instead:
`sudo mount -o ro,subvol=persist /dev/disk/by-uuid/ddb4bdb8-c522-4420-ba2d-ace00fc2054b /mnt/main`.
The main journal is then in `/mnt/main/var/log/journal`; read it with
`journalctl --directory=... --boot=<ID>`.

## How to work

1. **Diagnose first.**
   - Read the logs (`main-logs`, or `journalctl -b -1 -p err` inside the
     chroot) and SMART data.
   - Say what you think is wrong and why, then propose the smallest fix.
2. **Prefer rolling back to changing things.** The main boot menu lists older
   generations, and `nixos-rebuild boot --rollback` inside the chroot switches
   to the previous one.
3. **Use `nixos-rebuild boot`** (takes effect on the next main boot). Never
   `switch` or `test`: the chroot isn't a running system.
4. **Ask before anything that writes to the main disks or is hard to undo:**
   - entering the chroot, `nixos-rebuild`, the bootloader repair;
   - `fsck` with repairs, `btrfs check --repair` (only with a backup and an
     explicit request);
   - `mkfs`, `wipefs`, partitioning, `dd` or `ddrescue` onto a disk;
   - restoring subvolumes, deleting files or generations
     (`nix-collect-garbage -d`).
5. **Protect the user's uncommitted work** in the main repository: it may be
   the only copy.
   - Set changes aside with `git stash push --include-untracked`, which is
     reversible.
   - Never `git reset --hard`, `git checkout -- .`, `git clean`, or push.
6. **Copy data off a failing disk before trying repairs on it.** Check free
   space at the destination first.
7. **Never print, copy or upload secrets:**
   - `~/.claude/.credentials.json`, `~/.codex/auth.json`;
   - `/etc/recovery-root-password-hash`;
   - `/persist/root/.ssh` and anything decrypted by agenix.

## The user's guide

`/etc/nixos-recovery/guide.html` (Recovery Guide in the dock) walks through
the common problems. `~/readme.txt` lists the tools.
