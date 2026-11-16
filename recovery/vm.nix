# `nix run .#recovery-vm` boots this recovery configuration in QEMU, to try
# changes before installing them on the SN350. Log in with the password
# "recovery". The real disks are not attached.
{ lib, username, ... }:
{
  virtualisation.vmVariant = {
    virtualisation = {
      memorySize = 4096;
      cores = 4;
      # A tmpfs root: every run starts like a fresh install, and no disk image
      # is written to the current directory.
      diskImage = null;
      qemu.options = [
        "-vga none"
        "-device virtio-vga,xres=1920,yres=1080"
      ];
    };

    # NixOS's VM module already replaces the NVIDIA driver with modesetting.
    # The VM boots its kernel directly, without a bootloader, so keep the
    # recovery's EFI-only Limine setting and skip building the safe-graphics
    # entry it can never show.
    boot.loader.limine.biosDevice = lib.mkForce "nodev";
    specialisation = lib.mkForce { };

    # The Claude Code and Codex logins that apps/recovery-vm.sh shares at
    # /tmp/shared. The VM's home starts empty on every run.
    system.activationScripts.recovery-vm-logins = {
      deps = [ "users" ];
      text = ''
        home=/home/${username}
        install -d -m 0700 -o ${username} -g users "$home/.claude" "$home/.codex"
        for login in .claude/.credentials.json .claude.json .codex/auth.json; do
          if [[ -f /tmp/shared/$login && ! -e $home/$login ]]; then
            install -m 0600 -o ${username} -g users "/tmp/shared/$login" "$home/$login"
          fi
        done
      '';
    };

    # recovery-update copies the real password hash onto the SN350; the VM uses
    # a fixed test password instead.
    users.users = {
      root = {
        hashedPasswordFile = lib.mkForce null;
        password = "recovery";
      };
      ${username} = {
        hashedPasswordFile = lib.mkForce null;
        password = "recovery";
      };
    };
  };
}
