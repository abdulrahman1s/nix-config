# NixOS recovery disk

The recovery installation is a compact NixOS system with an IceWM desktop on
the WD Green SN350. It has its own EFI system partition and Limine installation,
so it remains bootable if the Samsung 990 Pro or its EFI partition fails.

The final SN350 layout is:

```text
1 GiB EFI | 24 GiB NixOS Recovery | remaining space SN350 data
```

## One-time partitioning with Disko

Repartitioning deletes the current SN350 filesystem. It appeared effectively
empty during planning, but verify its contents and back up anything important
before continuing.

The layout is declared in `recovery/disko.nix` and targets the immutable EUI
link `nvme-eui.e8238fa6bf530001001b448b4056230e`, not an unstable `nvmeXnY`
name. The wrapper also verifies model `WD Green SN350 1TB` and serial
`24301E803752` before Disko runs.

1. The operation can run from the current NixOS system because its root and Nix
   store are on the 990 Pro, not the SN350. First check for users of the current
   data mount and unmount it:

   ```bash
   sudo fuser -vm /mnt/SN350
   sudo umount /mnt/SN350
   ```

   Close any reported processes before unmounting. The guarded command refuses
   to continue while the SN350 or one of its partitions remains mounted.

   A live NixOS environment is optional. If used, make the repository available
   by mounting the main persisted subvolume:

   ```bash
   sudo mkdir -p /mnt/persist
   sudo mount -o subvol=persist /dev/disk/by-uuid/ddb4bdb8-c522-4420-ba2d-ace00fc2054b /mnt/persist
   cd /mnt/persist/home/abdulrahman/system-conf
   ```
2. Verify the SN350 contains nothing that must be retained.
3. From this repository, build and run the guarded Disko app:

   ```bash
   nix run .#recovery-partition -- --confirm-erase-sn350
   ```

4. The explicit `--confirm-erase-sn350` flag is the destructive confirmation;
   the generated Disko script does not ask a second time.
5. After Disko finishes, confirm `RECOVERYEFI`, `NIXOS-RECOVERY`, and `SN350`
   appear with `lsblk -f`. When running from the current system, continue
   directly to `recovery-update`; when using live media, reboot into the main
   NixOS installation first.

The wrapper refuses the operation when the target model or serial differs, when
any SN350 partition is mounted, or when the explicit erase flag is absent.

Only the SN350 should be changed. Do not modify the Samsung 990 Pro, SN770, or
their partitions.

## Install or update recovery

From this repository, install the current recovery closure and its independent
Limine bootloader:

```bash
nix run .#recovery-update
```

The command requests sudo for mounting and installing onto the recovery disk.
It verifies both partition types and labels before writing anything, copies the
currently decrypted root password hash, and installs Limine only to the SN350
EFI partition. Limine is installed at the removable-media fallback path and
does not change UEFI variables or replace the main disk's boot entry.

After installing the recovery system and rebuilding the main configuration,
the normal Limine menu contains a `NixOS Recovery` entry. It chainloads the
independent Limine installation on the SN350. If the main disk or its EFI
partition fails, open the motherboard's one-time firmware boot menu and select
the WD Green SN350 directly instead. Future updates use the same
`nix run .#recovery-update` command.

Activate the main configuration only after the SN350 has its new layout. That
changes `/mnt/SN350` to use the stable `SN350` filesystem label and adds the
recovery entry to the normal Limine menu.

## Recover the main system

Boot the SN350, then log into IceWM with the normal username and the same
password as the main system. The taskbar application menu provides GParted,
PCManFM, xterm, and the same Brave Origin Nightly browser as the main system.
GParted's PolicyKit prompt uses the same password. The browser has a separate
recovery profile stored on the recovery partition; it does not modify the main
system's browser profile.

Run the chroot command through sudo:

```bash
sudo system-chroot
```

The command mounts the main `root`, `nix`, `home`, and `persist` Btrfs
subvolumes plus the main EFI partition, restores the persisted flake bind mount,
and enters the installation with `nixos-enter`. For example, a repaired
configuration can be installed for the next boot with:

```bash
nixos-rebuild boot --flake /home/abdulrahman/system-conf#default
```

Exit the shell when finished; `system-chroot` then unmounts the filesystems in
reverse order. Activation commands remain explicit and should only be run after
reviewing and building the intended configuration.
