{ pkgs, utils, ... }:

let
  mkUmu = import ./umu-launcher-base.nix { inherit pkgs utils; };
in
mkUmu {
  name = "exe-offline";
  extraBinNames = [ "umu-run-offline" ];
  enableNetwork = false;
}
