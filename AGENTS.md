# AGENTS.md

Instructions for this personal NixOS flake. Optimize for one reliable daily-driver
machine; keep changes declarative, explicit, and easy to review.

| Item | Value |
| --- | --- |
| Repository | `/home/abdulrahman/system-conf` |
| User / hostname | `abdulrahman` / `nixos` |
| Configuration entry point | `configuration.nix` |
| Flake configuration | `nixosConfigurations.default` |
| User configuration | NixOS modules; no Home Manager |
| Instruction source | `AGENTS.md`; `CLAUDE.md` is a symlink to it |

Edit this file when updating instructions. Preserve the `CLAUDE.md` symlink.
Commands below assume the repository root; replace example paths and attributes
with the actual targets.

## Working boundaries

Complete requested edits and validation without asking for approval at each step.
Keep the diff focused; avoid unrelated cleanup, input updates, and compatibility
shims. Ask only about material ambiguities the request and repository cannot resolve.

These actions require explicit authorization; permission already given in the
current task is sufficient:

- **Activation:** `rebuild`, `nixos-rebuild switch`, `boot`, or `test`, direct
  `switch-to-configuration` calls, and manual execution of activation scripts.
  A request to edit, fix, build, or validate configuration does not authorize
  activation. A successful build does not authorize it either.
- **Garbage collection or generation deletion:** `nix-collect-garbage`,
  `nix store gc`, and equivalent cleanup commands.
- **Destructive or remote Git operations:** `git push`, `git reset --hard`,
  `git rebase -i`, and other history rewrites.

The user's `rebuild` alias expands to
`sudo nixos-rebuild switch --flake /home/abdulrahman/system-conf#default`.
Treat it as activation, never as a build shortcut.

## Start each task

1. Read `.agents/skills/rtk/SKILL.md`, using a file-reading tool to bootstrap when
   available. Route shell commands through `rtk` as documented there. Report a
   missing skill or executable; do not invent wrapper syntax or silently install it.
2. Run `rtk git status --short`. Inspect relevant unstaged and staged diffs before
   editing. Treat all pre-existing changes, including untracked files, as
   user-owned; never overwrite, revert, or stage unrelated work.
3. Locate the owning module through `configuration.nix` imports, top to bottom.
   Search with `rtk rg` / `rtk rg --files`. Check effective option values rather
   than inferring precedence from import order.
4. On a cold-start investigation, read the memory index below and relevant notes.
   Verify their claims against current code and live state. If memory is missing,
   continue from repository evidence.
5. Before changing installation paths or mutable state outside the Nix store,
   read `system/impermanence.nix` and establish the persistence requirements.

Project memory index:

```text
/home/abdulrahman/.claude/projects/-home-abdulrahman-system-conf/memory/MEMORY.md
```

## Repository map

| Path | Responsibility |
| --- | --- |
| `configuration.nix` | Main imports and global Nix settings |
| `flake.nix`, `flake.lock` | Inputs, substituters, and NixOS configuration |
| `specialArgs.nix` | User, host, identity, and LAN constants |
| `hardware-configuration.nix` | Generated hardware configuration |
| `packages.nix` | Native packages and package overrides |
| `local-packages/<name>.nix` | Non-trivial local package expressions |
| `services/` | System services, registered in `default.nix` |
| `modules/` | Features such as AI, gaming, development, and iOS |
| `system/` | Audio, graphics, networking, security, optimization, persistence |
| `terminal/` | Shell, terminal packages, dotfiles, and Ghostty |
| `config/zsh/` | Zsh functions sourced from `terminal/shell.nix` |
| `sandboxed-apps/` | NixPak-wrapped GUI apps and their registration |
| `sandboxed-apps/nixpak/` | `mkSandboxed` framework and sandbox helpers |

## Implementation rules

- Keep durable configuration in `.nix` files; explain any necessary mutable setup.
- Follow local conventions. Prefer explicit repetition over clever abstractions.
- Use `username` from `specialArgs.nix`; do not hardcode `abdulrahman` in modules.
  Use `users.users.${username}` for user options and packages. Scripts should use
  `$HOME` in the correct user context or Nix-generated paths based on `${username}`.
- Use `system.userActivationScripts` for necessary user activation work. It runs
  as the user with `$HOME`; `system.activationScripts` runs as root.
- Explain non-obvious reasons in comments; do not narrate obvious syntax.
- Run ordinary flake operations without `sudo` to avoid root-owned repository files.

### New files and Git visibility

A new file required by this Git-backed flake must be added to Git before evaluation,
including modules, scripts, and referenced assets. Review it, then stage only the
necessary new paths:

```bash
rtk git add -- path/to/new-file.nix
```

This narrow staging is authorized as part of validation. Do not use `git add .`
or `git add -A`. Existing tracked-file edits do not need staging for Nix builds.
Preserve the user's existing index, and identify newly staged paths in the handoff.

### Impermanence and activation scripts

Root and home roll back on every boot. Writes to `~/.local`, `~/.config`, or other
mutable paths are temporary unless persisted or recreated declaratively.

For each affected path, check `system/impermanence.nix`, persisted ancestors, and
symlink targets. Verify its backing mount with `rtk findmnt -T <path>`; inspect the
nearest existing parent if the path is absent. Establish whether state is disposable,
persisted, or recreated. A live mount alone does not prove durability across boots.

Before editing activation scripts, inspect existing files, directories, ownership,
and ancestor symlinks. Make scripts idempotent on clean and existing installations.
Preserve user data during migrations; do not delete conflicts just to make a script pass.

Evaluation and builds do not execute activation scripts. Keep build success,
script review, and runtime verification distinct in the final report.

## Packages and sandboxing

**Sandbox GUI applications with NixPak by default.** A native GUI package is an
exception when the user requests it or there is a concrete technical reason.
Explain that reason in the change or final summary.

### Sandboxed GUI application

1. Create `sandboxed-apps/<name>.nix` using `utils.mkSandboxed` from
   `sandboxed-apps/nixpak/default.nix`.
2. Use `sandboxed-apps/discord.nix` as the simple-app reference and
   `sandboxed-apps/browser.nix` for variants and tight browser permissions.
   Read the current helper implementation before choosing permissions.
3. Register the app in `sandboxed-apps/default.nix`: add both the `let` binding
   and its entry in `users.users.${username}.packages`. Registration is manual;
   creating the app file alone does not put it on `PATH` after activation.
4. Stage required new files, then run the validation below.

Available presets:

```text
network wayland x11 audio gpu usb controller webcam bluetooth kvm u2f
discovery portals notifications systray secrets mpris
```

Use presets first, `homeBinds` for app-specific paths under the user's home, and
`extraPerms` for other app-specific permissions. Use `pathBinding = "file"` or
`"dir"` when access should follow launch arguments.

- The framework is offline by default. Add `network` only when host network
  access is needed.
- Use narrow binds; never bind all of `$HOME`.
- Grant `org.freedesktop.portal.*` D-Bus access only when the app uses portals,
  and limit it to what the app requires.
- Investigate Chromium/Electron crashes before changing GPU permissions; do not
  remove `gpu` just to suppress a crash.
- Never work around failures with `--no-sandbox` or `--disable-features=Sandbox`.

### Native or locally packaged application

1. Check that the nixpkgs attribute is the intended software, not merely a matching
   name. Prefer it when suitable.
2. If the attribute represents different software, create a local package instead
   of changing that unrelated package's version.
3. Put non-trivial expressions in `local-packages/<name>.nix`, wire them through
   `packages.nix`, and add the package to `users.users.${username}.packages`.
4. Stage required new files, then run the validation below.

For prebuilt releases, use `autoPatchelfHook` for ELF binaries and `makeWrapper`
for runtime environment setup. Prefer system tools such as `pkgs.ffmpeg` when
upstream supports them. Disable self-updaters for Nix-managed packages or explain
why they remain enabled. Include `meta.mainProgram`, `meta.homepage`,
`meta.license`, `meta.platforms`, and `meta.sourceProvenance` for binary releases.

## Validation

Validate the final edits, including new files. Run the smallest relevant check,
then the whole-system build for configuration changes. Avoid redundant builds.

| Change | Required validation |
| --- | --- |
| Documentation only | Scoped whitespace checks and review of the edited text |
| Nix configuration or package | Parse changed Nix files, relevant targeted checks, then the system build |
| Zsh configuration | `zsh -n` on changed scripts, then the system build when deployed by this flake |
| Path-binding implementation or tests | The path-binding check, then the system build |
| Activation script | Relevant syntax checks, on-disk state and idempotence review, then the system build |
| Flake input update | Review `flake.lock`, build the system, and inspect the closure diff |

Check both unstaged and staged changes, scoped to task files. Inspect new untracked
documentation directly; do not stage it merely for whitespace validation.

```bash
rtk git diff --check -- path/to/changed-file
rtk git diff --cached --check -- path/to/changed-file
rtk nix-instantiate --parse path/to/changed-file.nix
rtk zsh -n config/zsh/changed-file.zsh
```

Run this targeted check only for changes to
`sandboxed-apps/nixpak/path-binding.nix` or its tests:

```bash
rtk nix build .#checks.x86_64-linux.pathbinding --no-link --no-update-lock-file
```

Whole-system build:

```bash
rtk nix build .#nixosConfigurations.default.config.system.build.toplevel --no-link --no-update-lock-file
```

When package or system closure changes matter, use this build **instead** and
compare only after it succeeds. Use an unused output-link path if
`/tmp/nixos-pending` belongs to other work.

```bash
rtk nix build .#nixosConfigurations.default.config.system.build.toplevel --out-link /tmp/nixos-pending --no-update-lock-file
rtk nvd diff /run/current-system /tmp/nixos-pending
```

This compares against the running system; differences may include previously
unactivated changes. Do not attribute the entire diff to the current task.

Use `--no-update-lock-file` during validation to prevent incidental lock updates.
If an intentional input change requires a lock update, perform it explicitly using
the workflow below, review it, and rerun validation.

Distinguish configuration failures from tool, network, or resource limitations.
Do not weaken sandboxing, change unrelated inputs, or claim success to bypass a failure.

## Flake input updates

Record the baseline and preserve pre-existing `flake.lock` changes. Update only
the requested inputs. Never hand-edit the lock file.

```bash
# One input
rtk nix flake update input-name

# All inputs
rtk nix flake update
```

Use `rtk nix flake lock` to add missing lock entries without intentionally updating
existing inputs. Review the resulting diff, build the system with an output link,
and run `nvd diff` as described above.

If the build fails, diagnose before rolling back. Restore only changes made by this
task from a known baseline; never reset the lock file to `HEAD` when that would
discard the user's earlier changes.

## Machine invariants

- **Hardware:** do not hand-edit `hardware-configuration.nix`. If regeneration is
  needed for the task, use `nixos-generate-config` and review its output.
- **Compatibility baseline:** `system.stateVersion` records installation
  compatibility, not the current NixOS release. Do not bump it during routine upgrades.
- **Binary caches:** `configuration.nix` forces `nix.settings.substituters` with
  `lib.mkForce`; add substituters there or they may be dropped. Preserve existing
  caches in both `flake.nix` and `configuration.nix`.
- **Agenix:** keep `/root/.ssh/id_ed25519` first in `age.identityPaths`. Do not rely
  only on `/home/${username}/.ssh/...`; home mounts too late for early decryption.
  The root key must be manually provisioned and available at the required boot stage.
- **Secrets:** never commit plaintext secrets or private keys, include their
  contents in logs, or interpolate them into Nix expressions or store outputs.
- **Nix store:** never hand-edit files under `/nix/store`.

## Diagnostics and known pitfalls

Use focused searches and effective option values:

```bash
rtk rg --type nix 'term' .
rtk rg 'term' config/zsh
rtk nix eval --json .#nixosConfigurations.default.config.option.path --no-update-lock-file
```

For a failed derivation, use its actual store path:

```bash
rtk nix log /nix/store/hash-name.drv
```

Inspect running-system failures only when relevant. These checks describe the
activated system, not an unactivated build:

```bash
rtk systemctl --failed --no-pager
rtk journalctl --user -b -p err --no-pager
rtk coredumpctl list COREDUMP_COMM=binary --since '1h ago'
```

Confirm these diagnostic leads against the current failure before applying a workaround.

| Symptom or area | Check |
| --- | --- |
| Empty `/run/agenix/*`; credential-dependent services fail with `status=243` | The early-boot root key may be missing or unavailable. Verify its presence and boot availability without exposing its contents. |
| Systemd service cannot mount a FUSE filesystem | Include `/run/wrappers/bin` on the service's `PATH` so it uses the NixOS `fusermount3` wrapper. |
| Brave nightly crashes with a file-upload clipboard URI containing Unicode path characters | Use `copy()` from `config/zsh/common.zsh`; it stages ASCII-safe names under `~/Downloads/.copy-stage/`. |
| Zsh `read` breaks after backgrounding | Keep monitor mode enabled; use `&!` to suppress job notifications instead of `NO_MONITOR`. |
| Unrelated coredump noise | Filter by the affected binary. This machine has a known PulseAudio SIGSYS loop. |

## Handoff

Review final status and task diffs, including staged files. Report:

- Changes and reasons, including native GUI exceptions and persistence impact.
- Checks passed, failed, or blocked, distinguishing build and runtime validation.
- Which new files were staged for flake visibility.
- Whether activation occurred and any remaining action for the user.

Suggest activation for a configuration change only after the whole-system build
passes for the final edits. If activation was already explicitly requested, proceed
within that authorization after validation; otherwise leave it to the user.
