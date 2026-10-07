# Génère microvm.vms à partir des nœuds de la topologie dont host == ce host.
{ config, inputs, ... }:
let
  inherit (config) cluster;
  guestModules = with config.flake.modules.nixos; [ microvm-guest k3s-node ];
in
{
  flake.modules.nixos.microvm-host = { config, lib, ... }:
    let
      clusterLib = import ../cluster/_lib.nix { inherit lib; };
      nodes = clusterLib.nodesOn cluster config.networking.hostName;
    in
    {
      imports = [ inputs.microvm.nixosModules.host ];

      microvm.vms = lib.mapAttrs (name: _: {
        autostart = true;
        restartIfChanged = true;
        specialArgs.node = name;
        config.imports = guestModules;
      }) nodes;
    };
}
