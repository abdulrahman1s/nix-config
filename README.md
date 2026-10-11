# NixOS system configuration

This is the configuration for one daily-driver machine. It is not a generic
installer: before using it, you must adapt its hardware, disks, network,
monitors, secrets, and persistent-data list to your machine.

See [features.md](features.md) for screenshots and a tour of the desktop,
sandboxing, impermanence, boot setup, terminal, and other features.

## Install

These steps assume NixOS is already installed and the machine uses Btrfs. Keep
a bootable NixOS USB and a verified backup nearby. The impermanence module wipes
the `root` and `home` subvolumes on every boot; do not enable it until its
subvolumes and persistence list are ready.

### 1. Fork and clone

Fork this repository so your machine-specific changes have somewhere to live,
then clone your fork:

```bash
git clone https://github.com/YOUR-USER/system-conf.git ~/system-conf
cd ~/system-conf
```

### 2. Set your identity and network

Edit [`specialArgs.nix`](specialArgs.nix) and replace the username, name, email,
hostname, LAN address, and LAN interface. Then search for remaining values that
belong to the original machine:

```bash
rg 'abdulrahman|192\.168\.1\.55|enp6s0|/home/abdulrahman'
```

Update or remove each relevant result, including paths in the Noctalia,
Vicinae, MangoHud, and WezTerm configuration files.

### 3. Adapt the hardware and disks

Generate a hardware configuration for your machine in a temporary directory:

```bash
sudo nixos-generate-config --show-hardware-config > /tmp/hardware-configuration.nix
```

Use it to adapt [`hardware-configuration.nix`](hardware-configuration.nix).
Review at least:

- filesystem UUIDs, mount points, CPU modules, and the EFI partition;
- the motherboard and NVIDIA modules in [`flake.nix`](flake.nix);
- Limine's Windows entry and display resolution;
- monitor connectors, modes, and GPU settings in `config/niri/` and
  [`system/graphics.nix`](system/graphics.nix);
- machine-specific audio, Bluetooth, recovery-disk, and extra-drive settings.

Do not copy `/tmp/hardware-configuration.nix` over the repository file without
merging it: the repository file also contains deliberate boot and filesystem
settings.

### 4. Prepare impermanence

Read [`system/impermanence.nix`](system/impermanence.nix) completely. Change its
Btrfs device, review every persisted path, and create the `root`, `home`, `nix`,
`persist`, `root-blank`, and `home-blank` subvolumes expected by this config.
Move every file you need to keep into `/persist` before enabling rollback.

For a safer first build, temporarily remove `./system/impermanence.nix` from the
imports in [`configuration.nix`](configuration.nix). Add it back only after the
disk layout, blank snapshots, backups, and persistence list are verified.

### 5. Replace the encrypted secrets

The committed `.age` files are encrypted for the original owner's SSH key and
cannot be decrypted by your machine. Replace the recipient in
[`secrets/secrets.nix`](secrets/secrets.nix), then recreate every referenced
secret with `agenix`.

At minimum, provide the user and root password hashes, the NextDNS upstream,
and the Cloudflare tunnel token, or disable the modules that consume them. With
impermanence enabled, provision the matching SSH identity at
`/root/.ssh/id_ed25519` and `/persist/root/.ssh/id_ed25519` before booting the
new system.

### 6. Review and build

Check the diff, parse the main configuration, and build the complete system:

```bash
git diff --check
nix-instantiate --parse configuration.nix
nix build .#nixosConfigurations.default.config.system.build.toplevel --no-link
```

Fix every evaluation or build error before continuing. To inspect how the new
closure differs from the running system:

```bash
nix build .#nixosConfigurations.default.config.system.build.toplevel \
  --out-link /tmp/nixos-pending
nvd diff /run/current-system /tmp/nixos-pending
```

### 7. Activate

Only after the build, disk layout, secrets, and backups are verified, activate
the configuration:

```bash
sudo nixos-rebuild switch --flake .#default
```

Reboot once and verify the bootloader, login, networking, persisted data, and
desktop. If you kept impermanence disabled for the first activation, prepare
and test it separately before adding its import back.

## Updating

```bash
nix flake update
nix build .#nixosConfigurations.default.config.system.build.toplevel --no-link
sudo nixos-rebuild switch --flake .#default
```

Review the lock-file diff and successful build before switching.

## Binary cache

The [cache workflow](.github/workflows/build-cache.yml) checks installed package
outputs on every push to `master` and after the nightly updater, which refreshes
all inputs in `flake.lock`. It builds only package outputs missing from the
configured substituters and uploads only outputs built by GitHub Actions to the private Cloudflare
R2 bucket `abdulrahman1s-nix-cache` through an
[authenticated Worker](cloudflare/nix-cache/worker.js). The cache URL and public
signing key are declared in both [`flake.nix`](flake.nix) and
[`configuration.nix`](configuration.nix).
Outputs available from other configured caches are substituted and are not
uploaded to R2. Each direct package build has a 45-minute limit. Failed
derivation hashes are recorded privately in R2 so later runs can continue with
the remaining packages without repeating known failures. A manually dispatched
run can enable **Retry unchanged failures**; changed derivations retry
automatically because their store hashes change.

Keep public bucket URLs and custom domains disabled. The Worker requires a
read token for downloads and a separate write token for uploads. Its secrets
are `READ_TOKEN` and `WRITE_TOKEN`. GitHub Actions uses repository secrets
`NIX_CACHE_READ_TOKEN`, `NIX_CACHE_WRITE_TOKEN`, and
`NIX_CACHE_SIGNING_KEY`. This machine keeps the read token in the persisted
`~/.aws/nix-cache.netrc` file, which the Nix daemon reads through
`nix.settings.netrc-file`. Unauthenticated requests cannot read or write R2
objects. Never commit any of these secrets.

Wait for a successful cache workflow for the committed configuration before
rebuilding this machine. Local, unpushed edits can still require local builds;
Nix also falls back to a local build if CI fails or a cache path is unavailable.
R2 storage and request usage may incur charges as old cache objects accumulate.

## License

[MIT](LICENSE). Third-party packages keep their own licenses.
