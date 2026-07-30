# AGENTS.md

Personal NixOS flake for one daily-driver machine:

- User: `abdulrahman`
- Hostname: `nixos`
- Entry point: `configuration.nix`
- `CLAUDE.md` is a symlink; edit this file as the source of truth
- No home-manager; user configuration is managed by NixOS modules

## Start Here

1. Read `/home/abdulrahman/.codex/RTK.md`; prefix every shell command with `rtk`.
2. Check the worktree before editing: `rtk git status --short`.
3. Treat existing modifications as user-owned. Do not revert, overwrite, or stage unrelated changes.
4. On a cold-start investigation, read the project memory index described below.
5. Prefer `rg` and `rg --files` for search.
6. Follow `configuration.nix` imports top to bottom when locating settings.
7. Do not run activation commands unless the user explicitly asks.
8. If the flake imports a new file, stage that file before evaluation or Nix will not see it.

New flake-visible files need:

```bash
rtk git add path/to/new-file.nix
```

Stage only newly created paths required by the evaluation. Tracked-file edits do not
need staging for `nix build`.

## Project Rules

- This is a daily-driver config, not a reusable module library. Optimize for this user.
- Keep configuration declarative in `.nix` files. Mutable state is only an escape hatch.
- Prefer explicit repetition over clever abstractions.
- Do not hardcode `abdulrahman` in Nix modules. Use `${username}` from
  `specialArgs.nix`; scripts should use `$HOME` or Nix-interpolated paths derived
  from `${username}`.
- User config belongs in `users.users.${username}` or `system.userActivationScripts`.
- Comments should explain non-obvious why, not restate what code does.
- Do not add backwards-compatibility shims. Change the personal config directly.

## Activation Rule

The user has:

```bash
rebuild='sudo nixos-rebuild switch --flake /home/abdulrahman/system-conf#default'
```

Never run `rebuild`, `nixos-rebuild switch`, `nixos-rebuild boot`, or any other activation command without explicit user permission. A successful build is not permission to activate.

## Validation

Match validation to the change. Documentation-only edits need a scoped
`git diff --check`; configuration changes need the smallest relevant check
followed by the whole-system build.

```bash
rtk git diff --check -- path/to/changed-file
rtk nix-instantiate --parse file.nix
rtk zsh -n config/zsh/file.zsh
rtk nix build .#checks.x86_64-linux.pathbinding
rtk nix build .#nixosConfigurations.default.config.system.build.toplevel --no-link
rtk nix build .#nixosConfigurations.default.config.system.build.toplevel --out-link /tmp/nixos-pending
rtk nvd diff /run/current-system /tmp/nixos-pending
rtk nix eval --json .#nixosConfigurations.default.config.option.path
```

Use the path-binding check only for `sandboxed-apps/nixpak/path-binding.nix` or
its tests. Run the whole-system build before suggesting activation for a
configuration change. Use the out-link plus `nvd diff` when package or system
closure changes matter.

A Nix build does not execute activation scripts. When changing one, also inspect
the relevant current on-disk state, including ancestor symlinks, and make the
script idempotent across both clean installs and existing machines.

## Layout

```text
configuration.nix          Main import list and global Nix settings
flake.nix / flake.lock     Inputs, substituters, NixOS configuration
specialArgs.nix            User, host, identity, and LAN constants
hardware-configuration.nix Generated hardware config; do not hand-edit
packages.nix               Native user/system packages and package overrides
services/                  System services; default.nix imports them
modules/                   Feature modules: ai, gaming, development, ios, etc.
system/                    OS layer: audio, graphics, networking, security, optimization
terminal/                  Shell, packages, dotfiles, ghostty
config/zsh/                Zsh function library, sourced from terminal/shell.nix
sandboxed-apps/            NixPak-wrapped GUI apps
sandboxed-apps/nixpak/     mkSandboxed framework and sandbox helpers
```

## Package Decisions

Default rule: GUI apps should be sandboxed with NixPak.

Native GUI packages are allowed only when the user asks for it or there is a specific technical reason. Make the reason visible in the change or in the final summary.

For native packages:

1. Prefer nixpkgs when the attr is the right software.
2. If a nixpkgs attr has the same name but is different software, do not override its version and hope. Add a local package expression.
3. Put local package expressions in `local-packages/<name>.nix` when they are non-trivial.
4. Add the package to `users.users.${username}.packages`.
5. If a new package file is imported by the flake, stage it before validation.

For prebuilt binaries on NixOS:

- Use `autoPatchelfHook` for ELF binaries.
- Use `makeWrapper` for runtime environment.
- Prefer system tools such as `pkgs.ffmpeg` over bundled tools when upstream supports it.
- Disable or explain app self-updaters when the package is Nix-managed.
- Include `meta.mainProgram`, `homepage`, `license`, `platforms`, and `sourceProvenance` for binary releases.

## Sandboxed Apps

Use `utils.mkSandboxed { ... }` from `sandboxed-apps/nixpak/default.nix`.

Each sandboxed app needs:

1. `sandboxed-apps/<name>.nix`
2. A `let` binding in `sandboxed-apps/default.nix`
3. An entry in `users.users.${username}.packages`

Available presets:

```text
network wayland x11 audio gpu usb controller webcam bluetooth kvm u2f
discovery portals notifications systray secrets mpris
```

The framework is offline by default; only the `network` preset enables host
network access. Use presets first, `homeBinds` for app-specific paths below the
user's home, and `extraPerms` for other app-specific permissions. Use
`pathBinding = "file"` or `"dir"` when access should follow launch arguments.
Use narrow binds; never bind all of `$HOME`.

Sandbox checks:

- Add `network` only when the app actually needs it.
- No `org.freedesktop.portal.*` D-Bus access unless the app actually uses portals.
- Do not remove `gpu` from Chromium/Electron apps just to avoid a crash; investigate first.
- `sandboxed-apps/browser.nix` is the reference for tight browser permissions.
- `sandboxed-apps/default.nix` is hand-maintained. Missing registration means the app is not on PATH after rebuild.

## Common Workflows

Add a sandboxed GUI app:

1. Create sandboxed-apps/<name>.nix.
2. Model simple apps after discord.nix; model multi-variant apps after browser.nix.
3. Register it in sandboxed-apps/default.nix in both the let block and package list.
4. Run parse/build validation.
5. Suggest rebuild; do not run it.

Add a native package:

1. Confirm it should not be sandboxed.
2. Use nixpkgs directly if the attr is correct.
3. Otherwise create local-packages/<name>.nix and call it from packages.nix.
4. Stage the new local package file.
5. Parse the changed Nix files.
6. Build the toplevel.

Update flake inputs:

```bash
rtk nix flake update
rtk nix build .#nixosConfigurations.default.config.system.build.toplevel --out-link /tmp/nixos-pending
rtk nvd diff /run/current-system /tmp/nixos-pending
```

For one input, use:

```bash
rtk nix flake lock --update-input input-name
```

If a build fails after an input update, diagnose before rolling back. Do not
overwrite pre-existing `flake.lock` changes; restore with Nix or Git only when
the task's baseline is known. Never hand-edit `flake.lock`.

Find a setting:

```bash
rtk rg --type nix 'term' /home/abdulrahman/system-conf
rtk rg 'term' config/zsh
rtk nix eval --json .#nixosConfigurations.default.config.option.path
```

## Diagnostics

Build log for a failed derivation:

```bash
rtk nix log /nix/store/hash-name.drv
```

Eval debugging:

```bash
rtk nix repl --expr 'builtins.getFlake "/home/abdulrahman/system-conf"'
```

Inside the repl:

```text
:p outputs.nixosConfigurations.default.config.option.path
```

Activated-system checks, only when relevant:

```bash
rtk systemctl --failed --no-pager
rtk journalctl --user -b -p err --no-pager
rtk coredumpctl list COREDUMP_COMM=binary --since '1h ago'
```

Filter coredumps by the binary you care about; pulseaudio has a known SIGSYS loop on this machine.

## Critical Invariants

- `flake.lock` is reproducibility-critical. Update it only with `nix flake update` or `nix flake lock --update-input`.
- `hardware-configuration.nix` is generated. Regenerate with `nixos-generate-config`; do not hand-edit.
- `system.stateVersion` records the original installation compatibility baseline. Do not bump it as part of an ordinary upgrade.
- `configuration.nix` forces `nix.settings.substituters` with `lib.mkForce`. Add substituters there or they can be silently dropped.
- Do not remove existing binary caches from `flake.nix` or `configuration.nix`, even if they look unused.
- `age.identityPaths` must include `/root/.ssh/id_ed25519` first. Do not point agenix only at `/home/${username}/.ssh/...`; `/home` mounts too late for early boot decryption.
- Never commit plaintext secrets or private keys, or interpolate them into the Nix store.

## Known Gotchas

- `system.userActivationScripts` runs as the user with `$HOME`; `system.activationScripts` runs as root.
- Evaluation and build do not run activation scripts, so successful builds cannot validate their behavior against stale mutable state.
- Agenix early boot requires a manually provisioned root-filesystem key at `/root/.ssh/id_ed25519`. If missing, `/run/agenix/*` stays empty and services using credentials fail with `status=243`.
- Systemd services that mount FUSE filesystems need `/run/wrappers/bin` on `PATH` so they use the NixOS `fusermount3` wrapper.
- Brave nightly can crash when a file-upload clipboard URI contains some Unicode path characters. Use `copy()` from `config/zsh/common.zsh`; it stages files under `~/Downloads/.copy-stage/` with ASCII-safe names.
- `NO_MONITOR` in zsh can break `read` after backgrounding. Keep monitor mode on and use `&!` to silence job notifications.

## Do Not

- Do not run activation commands without explicit permission.
- Do not run `nix-collect-garbage`, `nix store gc`, or other generation-deleting commands without explicit ask.
- Do not run `git push`, `git reset --hard`, `git rebase -i`, or history rewrites without explicit ask.
- Do not hand-edit `flake.lock`, `hardware-configuration.nix`, or anything in `/nix/store`.
- Do not add `--no-sandbox` or `--disable-features=Sandbox` to fix sandboxed app problems.
- Do not use `sudo` for normal flake operations such as `nix flake update`; it creates root-owned repo files.

## Project Memory

Start with the index:

```text
/home/abdulrahman/.claude/projects/-home-abdulrahman-system-conf/memory/MEMORY.md
```

It contains short links to focused notes. Read only the notes relevant to the
current investigation, and verify potentially stale claims against the live
worktree.
