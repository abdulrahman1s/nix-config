# Maintained packages

This directory is part of the repository's main flake. `packages.x86_64-linux`
exposes `codex`, `claude-code`, `brave-origin`, `noctalia`, and `niri`.
The NixOS configuration consumes those same outputs. Brave Origin stays inside
its existing NixPak wrappers on the daily-driver system.

The daily workflow checks official stable releases for the three binary packages.
It pins their versions and hashes in `versions.json`, updates the dedicated
`nixpkgs-packages` and `noctalia` flake inputs for niri and Noctalia, builds all five
packages, evaluates the NixOS system, and commits passing updates to the
repository's default branch. Updates take effect on the machine only after
the flake is pulled and the system is activated separately. GitHub Actions
needs write access to repository contents, and branch protection must permit
its commits.
