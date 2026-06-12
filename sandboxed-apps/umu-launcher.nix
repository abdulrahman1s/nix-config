{ pkgs, utils, ... }:

let
  mkUmu = import ./umu-launcher-base.nix { inherit pkgs utils; };
in
mkUmu {
  name = "exe";
  extraBinNames = [ "umu-run" ];
  enableNetwork = true;
}
