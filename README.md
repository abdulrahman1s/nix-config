<div align="center">

# NixOS, Tuned for the Daily Drive

**One machine. One user. One reproducible system.**

[![NixOS](https://img.shields.io/badge/NixOS-unstable-5277C3?logo=nixos&logoColor=white)](https://nixos.org/)
[![Flakes](https://img.shields.io/badge/Nix-flakes-7EBAE4?logo=nixos&logoColor=white)](https://nixos.wiki/wiki/Flakes)
[![Wayland](https://img.shields.io/badge/Wayland-Niri-FFBC00)](https://github.com/YaLTeR/niri)
[![License](https://img.shields.io/badge/license-MIT-2ea44f)](LICENSE)

</div>

This is the complete NixOS configuration for my personal workstation:
`abdulrahman@nixos`. It is not a starter template or a portable framework.
It is a real daily-driver configuration built around declarative state,
sandboxed desktop applications, and a keyboard-first Wayland workflow.

```text
boot -> NixOS -> Niri -> Noctalia -> sandboxed apps
             \-> Docker, gaming, development, AI tooling
```

## What Makes It Different

- **GUI applications are sandboxed by default.** NixPak wrappers grant only
  the paths, devices, D-Bus names, and sockets each application needs.
- **The desktop is Wayland-native.** Niri, Noctalia, Ghostty, portals, and
  focused shell utilities form the main interaction layer.
- **It is aggressively declarative.** Packages, services, dotfiles, shell
  functions, networking, and application permissions live in this flake.
- **It is built for actual hardware.** CachyOS kernels, NVIDIA tuning,
  OpenRazer, OpenRGB, a Logitech wheel, Steam, Gamescope, and MangoHud are
  configured as part of the system.
- **Local infrastructure is first-class.** Docker, Dokploy, Cloudflare
  Tunnel, encrypted rclone backups, local HTTPS development domains, and a
  LAN-only remote-control service are managed alongside the desktop.

## System Map

| Area | What lives there |
| --- | --- |
| `configuration.nix` | Entry point and canonical import order |
| `system/` | Audio, graphics, networking, security, optimization |
| `modules/` | Development, gaming, AI, iOS, remote control, Vicinae |
| `sandboxed-apps/` | NixPak-wrapped GUI applications |
| `terminal/` | Shell, packages, Ghostty, dotfile activation |
| `config/` | Application and shell configuration |
| `secrets/` | agenix-encrypted secrets and recipient keys |

## Sandboxing Model

Desktop applications are assembled with
[`mkSandboxed`](sandboxed-apps/nixpak/default.nix). Shared presets cover
Wayland, X11, audio, GPU, portals, notifications, secrets, discovery, USB,
and controllers. App-specific modules then add narrow filesystem bindings.

For example, the browser receives access to its own profile and selected
download paths rather than a wholesale `$HOME` bind. Chromium variants,
Discord, MPV, Minecraft, and UMU launchers all use the same framework.

## Secrets

Secrets are managed with [agenix](https://github.com/ryantm/agenix). The
encrypted `.age` files live in [`secrets/`](secrets/) and are safe to commit;
[`secrets/secrets.nix`](secrets/secrets.nix) lists the recipient public keys.
At activation agenix decrypts each one to `/run/agenix/<name>`; services read it
from `config.age.secrets.<name>.path` and receive it through a systemd
`LoadCredential` rather than an environment variable.

Tracked secrets: the Cloudflare Tunnel token, the rclone backup config, the
Dokploy database password and auth secret, and the NextDNS upstream.

Edit them with the bundled `agenix` CLI (`agenix -e secrets/<name>.age`). Never
place a plaintext secret in a Nix string: evaluated strings are copied into the
world-readable Nix store, which is exactly what the encrypted-file approach
avoids.

The remote-control bearer token is separate: it is generated locally on first
activation at `/etc/remote-control.token`. The service binds only to the
configured wired LAN address, and the firewall opens its port only on that
interface.

## Validation

None of these commands activates the configuration:

```bash
# Parse one file
nix-instantiate --parse configuration.nix

# Evaluate and build the complete system
nix build .#nixosConfigurations.default.config.system.build.toplevel --no-link

# Build a reviewable pending closure
nix build .#nixosConfigurations.default.config.system.build.toplevel \
  --out-link /tmp/nixos-pending
nvd diff /run/current-system /tmp/nixos-pending
```

Activation is deliberately separate:

```bash
sudo nixos-rebuild switch --flake .#default
```

## Adapting It

Start with [`specialArgs.nix`](specialArgs.nix), then replace the generated
hardware configuration, disk UUIDs, network interface, LAN address, GPU and
motherboard modules, and personal paths. Review every sandbox permission and
service before enabling it.

This repository describes one specific machine. Treat it as an implementation
to inspect and borrow from, not a configuration to deploy unchanged.

## License

The configuration is available under the [MIT License](LICENSE). Downloaded
packages and third-party software retain their own licenses.
