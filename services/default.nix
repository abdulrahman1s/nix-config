{ ... }:

{
  imports = [
    ./cloudflare.nix
    ./juicefs.nix
    ./avahi.nix
    ./dokploy.nix
    ./radio.nix
    ./slim.nix
  ];
}
