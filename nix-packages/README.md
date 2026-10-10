# Maintained packages

`nix-packages/` holds packages exported by the flake, with release pins in
`versions.json` where needed. `local-packages/` holds packages used only by this
machine's NixOS configuration or its sandbox wrappers. Keep each derivation with
its export and version metadata when it is a flake package.

This directory is part of the repository's main flake. `packages.x86_64-linux`
exposes `codex`, `chatgpt`, `photocraft`, `filmcraft`, `sklauncher`, `claude-code`,
`brave-origin`, `noctalia`, and `niri`.
The NixOS configuration consumes those same outputs. ChatGPT includes Codex
desktop workflows; it runs natively so its agent can work in user-selected
project directories. SKlauncher 4 beta, PhotoCraft, FilmCraft, and Brave Origin use NixPak
wrappers on the daily-driver system.

The daily workflow checks official releases for the seven binary packages.
It pins their versions and hashes in `versions.json`, updates the
`noctalia` flake input, builds all nine
packages, evaluates the NixOS system, and commits passing updates to the
repository's default branch. Updates take effect on the machine only after
the flake is pulled and the system is activated separately. GitHub Actions
needs write access to repository contents, and branch protection must permit
its commits.

Niri comes from the main nixpkgs input.
