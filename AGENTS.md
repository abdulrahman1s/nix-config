# AGENTS.md

A NixOS flake managing the entire personal system for a single user
(`abdulrahman`, hostname `nixos`). Entry point: `configuration.nix`.
Flake inputs and substituters in `flake.nix`. This file is symlinked to
`CLAUDE.md` so any agent that reads either path sees the same source.

## What kind of project this is

- **Personal daily-driver.** Not a library; not multi-user. Optimize for this user's workflow, not hypothetical others.
- **Sandboxed by default** for anything GUI — via NixPak's `mkSandboxed` in `sandboxed-apps/nixpak/`. New native packages on `users.users.${username}.packages` should have a clear reason for _not_ being sandboxed.
- **Declarative over stateful.** Configuration lives in `.nix` files; mutable state outside the flake is tolerated only as an escape hatch.
- **Explicit over magic.** The user prefers a literal three-line repetition to a clever abstraction. Don't over-factor.
- **No home-manager.** User-level config rides on `users.users.${username}` or `system.userActivationScripts`.

## Validation

None of these change the running system. Run them before suggesting activation.

```bash
# Parse one .nix file (syntax only)
nix-instantiate --parse <file>.nix

# Whole-system eval + build, no switch
nix build .#nixosConfigurations.default.config.system.build.toplevel --no-link

# Pre-flight diff: build pending closure, then nvd diff
nix build .#nixosConfigurations.default.config.system.build.toplevel --out-link /tmp/nixos-pending
nvd diff /run/current-system /tmp/nixos-pending

# Zsh syntax
zsh -n config/zsh/<file>.zsh

# Resolve an option (useful when it falls through to upstream defaults)
nix eval --json .#nixosConfigurations.default.config.<option.path> | jq
```

## Activation

The user has `rebuild` aliased to:

```bash
sudo nixos-rebuild switch --flake /home/abdulrahman/system-conf#default
```

**Never run `rebuild` or any other activating `nixos-rebuild` variant without explicit user permission.** A clean validation build does not imply consent to activate.

## Layout

```
configuration.nix       entry; its imports list defines the canonical lookup order
flake.nix / flake.lock  inputs: nixpkgs, nixos-hardware, nixpak, nix-cachyos-kernel,
                        brave-previews, noctalia
specialArgs.nix         injected via _module.args: username, fullName, email, hostname
hardware-configuration.nix  generated; do not hand-edit
packages.nix            system-wide packages
services/                system services, one file per service (cloudflare, juicefs,
                        avahi, dokploy, slim); default.nix is the imports aggregator
modules/                feature toggles (ai, gaming, development, ios, niri-dynamic-float,
                        remote-control, vicinae)
system/                 OS layer (audio, graphics, networking, security, optimization)
terminal/               shell, packages, dotfiles, ghostty (sources config/zsh/)
sandboxed-apps/         NixPak-wrapped GUI apps (hand-registered in default.nix)
sandboxed-apps/nixpak/  framework: mkSandboxed (default.nix), mkPathBindingLauncher
                        (path-binding.nix), mkPrivateUserSandbox (private-user.nix),
                        sandboxed xdg-open (xdg-utils.nix)
config/zsh/             zsh function library; sourced from terminal/shell.nix
```

When searching for where a setting lives, follow the `configuration.nix` import order top-to-bottom.

## Invariants

Things that must stay true. Flag any change that would break one.

- **`username` is never hardcoded** — read from `specialArgs.nix` as `${username}`; in scripts use `$HOME` or `/home/${username}/...` formed from it.
- **GUI apps go through `mkSandboxed`.** A new native GUI binary on `users.users.${username}.packages` is a smell — wrap it or justify the exception.
- **`sandboxed-apps/default.nix` is hand-maintained.** A new app file must be both `call`ed in the `let` block AND appended to the packages list, or it never reaches the user's PATH.
- **`flake.lock` is reproducibility-critical** — update only via `nix flake update` or `nix flake lock --update-input <name>`. Never hand-edit.
- **`hardware-configuration.nix` is generated** — regenerate via `nixos-generate-config`, don't hand-edit.
- **Substituter list in `configuration.nix` uses `lib.mkForce`.** Adding more substituters elsewhere without `mkForce` is silently dropped at module merge time.
- **The agenix identity must resolve to a root-filesystem path.** `age.identityPaths` (`system/networking.nix`) lists `/root/.ssh/id_ed25519` first — a manually-provisioned copy on the `/` subvolume. Don't point it _only_ at `/home/${username}/.ssh/...`: `/home` is a separate subvolume mounted ~3s too late for early-boot decryption (see Gotchas).
- **Comments are rare.** Only where the _why_ isn't obvious. Don't restate what code does.
- **No backwards-compat shims.** Change code outright; this is a personal config, not a library.

## Sandboxed apps (the most-edited area)

The wrapper is `mkSandboxed { … }` in `sandboxed-apps/nixpak/default.nix`. Each app gets its own file under `sandboxed-apps/<name>.nix` and is registered in `sandboxed-apps/default.nix`. Browser variants share a local `mkBrave` helper in `browser.nix`; Brave runs as the normal login user and stores its profile under the host `~/.config/BraveSoftware/Brave-Origin-Nightly`.

**Available presets** (defined in `nixpak/default.nix`):
`network` · `wayland` · `x11` · `audio` · `gpu` · `usb` · `controller` · `portals` · `notifications` · `systray` · `secrets` · `discovery`

Pull binds from presets first; add `extraPerms` only for app-specific paths. Optional `resourceLimits = { cpu = "..."; mem = "..."; }` wraps the launcher in `systemd-run --user --scope`.

**Sandbox don'ts**

- No `network` preset for an offline-only app.
- No wholesale `$HOME` bind — narrow binds only. `sandboxed-apps/browser.nix` is the reference for tight permission scoping.
- No `org.freedesktop.portal.*` D-Bus access unless the app actually uses portals.
- No silent removal of a preset to "fix" a bug — investigate first. Removing `gpu` from an Electron app breaks hardware video decode without an error.

## Common workflows

**Add a sandboxed app**

1. Write `sandboxed-apps/<name>.nix`. Model after `discord.nix` (single binary) or `browser.nix` (multi-variant with a local helper).
2. In `sandboxed-apps/default.nix`: add `<app> = call ./<name>.nix;` to the `let` block AND append the package to `users.users.${username}.packages`.
3. Validate: `nix build .#nixosConfigurations.default.config.system.build.toplevel --no-link`.
4. Suggest `rebuild` — don't run it.

**Update flake inputs**

1. `nix flake update` (or `nix flake lock --update-input <name>` for a single one).
2. Build pending closure: `nix build .#nixosConfigurations.default.config.system.build.toplevel --out-link /tmp/nixos-pending`.
3. `nvd diff /run/current-system /tmp/nixos-pending`.
4. Show diff, wait for go-ahead, user runs `rebuild`.
5. If a build fails: `nix flake lock --override-input <name> <previous-flake-ref>` (or restore the file from git if tracked).


**Inspect closures with nvd**

Upstream: <https://khumba.net/projects/nvd/>

- `nvd diff /run/current-system /tmp/nixos-pending` is the standard pre-activation review after building an out-link.
- `nvd list /tmp/nixos-pending` shows packages in a built closure.
- `nvd history /nix/var/nix/profiles/system` shows system generation history.

**Find where a setting lives**

- First pass: `rg --type nix '<term>' /home/abdulrahman/system-conf`.
- For options that fall through to upstream defaults: `nix eval --json .#nixosConfigurations.default.config.<option.path>` (no hit = literal default; hit but no rg match = set indirectly).
- For shell functions: grep `config/zsh/`.
- Search priority follows `configuration.nix` imports.

## Diagnostics

When something fails or misbehaves, reach for these in order:

```bash
# A specific derivation failed — show the build log
nix log /nix/store/<hash>-<name>.drv

# Eval-time error — drop into the repl with the flake loaded
nix repl --expr 'builtins.getFlake "/home/abdulrahman/system-conf"'
# inside: :p outputs.nixosConfigurations.default.config.<path>

# System activated, but something's broken
systemctl --failed --no-pager
journalctl --user -b -p err --no-pager | tail -50

# Recent coredumps (filter by binary — see Gotchas re: pulseaudio noise)
coredumpctl list COREDUMP_COMM=<binary> --since '1h ago'
```

For sandboxed Chromium-based app crashes, the in-process signal handler gets masked by crashpad. Use the `brave-debug` variant in `sandboxed-apps/browser.nix` (already pre-baked with `--enable-logging=stderr --v=1` and clipboard/data-transfer vmodule). Symbols won't be present in nightly builds — chasing internal Chromium crashes from this side is a dead end; pivot or upstream.

## Gotchas

Each one with what to actually do.

- **`system.userActivationScripts` vs `system.activationScripts`** — first runs as the user with `$HOME` set, second as root. Pick the one matching where the target path lives.
- **agenix identity — must live on the root filesystem, provisioned by hand.** With `boot.initrd.systemd.enable`, the `agenixInstall` activation snippet runs in early boot (~2.7s) before `home.mount` (~5.9s). If `age.identityPaths` points at the user's `/home/${username}/.ssh/id_ed25519`, agenix logs `[agenix] WARNING: no readable identities found!`, decrypts nothing, and `/run/agenix/*` stays empty — so every consumer (`dnsproxy`, `cloudflared`, `dokploy`, `juicefs`) dies at systemd step `CREDENTIALS` (`status=243`). Fix: keep a copy of the identity on the `/` subvolume at `/root/.ssh/id_ed25519` (listed first in `system/networking.nix`). It is **mutable state outside the flake** — the private key is never committed or placed in the Nix store. Provision after a fresh install / key rotation: `sudo install -d -m700 /root/.ssh && sudo install -m600 /home/${username}/.ssh/id_ed25519 /root/.ssh/id_ed25519`. Confirm decryption with `journalctl -b | grep agenix` (no "no readable identities") and `ls /run/agenix`.
- **Forgot to register a new sandbox file in `sandboxed-apps/default.nix`** — if the user reports "the new app isn't on my PATH after rebuild", check this first.
- **Substituter `lib.mkForce` swallow** — if a new substituter set elsewhere doesn't take effect, the `mkForce` in `configuration.nix` is why. Add it to that list, don't fight it from another module.
- **Brave nightly + file clipboard paste** — pasting a path with certain Unicode codepoints (e.g. U+FF5C `｜`, yt-dlp's `|` substitution) into a file-upload UI traps the browser on a CHECK; Brave's sandbox also only binds `~/Downloads`, so paths outside it can't be read even if they don't crash. `copy()` in `config/zsh/common.zsh` handles both: it hardlinks (falls back to reflink/cp) the file into `~/Downloads/.copy-stage/` with an ASCII-sanitized name (`iconv //TRANSLIT//IGNORE` + `tr`) and puts that as a `text/uri-list` `file://` URI on the clipboard. yt-dlp invocations in `mp3()`/`mp4()` use `--restrict-filenames` to avoid producing the bad names in the first place. If you bypass `copy()` and put a raw non-ASCII path on the clipboard, the crash returns.
- **Pulseaudio SIGSYS loop on this box** — pulseaudio crashes on a seccomp violation roughly once per second. When grepping `coredumpctl list` or `journalctl` during a crash investigation, filter by the binary you care about; otherwise pulseaudio entries drown out the signal.
- **`NO_MONITOR` (zsh `setopt nomonitor`) breaks `read` after backgrounding** — in shell functions that background a pipeline then `read`, leave `MONITOR` on and silence the job-notification with `&!` instead of toggling `NO_MONITOR`. The latter wedges subsequent reads.

## Don'ts

Explicit denylist for risky operations:

- Don't run `rebuild`, `nixos-rebuild switch`, `nixos-rebuild boot`, or any activation command without explicit user permission.
- Don't run `nix-collect-garbage` (especially `-d`) or `nix store gc` without explicit ask — it deletes recovery generations.
- Don't `git push`, `git reset --hard`, `git rebase -i`, or any history-rewriting op without explicit ask.
- Don't hand-edit `flake.lock`, `hardware-configuration.nix`, or anything under `/nix/store/`.
- Don't remove any binary-cache substituter from `flake.nix` `nixConfig` or `configuration.nix` `nix.settings`, even ones that look unused. The user keeps them deliberately.
- Don't add `--no-sandbox` / `--disable-features=Sandbox` to a misbehaving app as a fix — investigate the real cause.
- Don't `sudo` a normal-workflow command (`sudo nix flake update`, etc.) — that creates root-owned files in the repo and breaks the next user-mode operation.

## Pointers

- Persistent agent memory for this project: `/home/abdulrahman/.claude/projects/-home-abdulrahman-system-conf/memory/`. Index is `MEMORY.md` (one-line entries pointing at per-topic files). Check it on cold start.
- This file is the source of truth; `CLAUDE.md` is a symlink to it.
