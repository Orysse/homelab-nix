{ config, inputs, ... }:
let
  inherit (config) cluster;
  guestModules = with config.flake.modules.nixos; [ microvm-guest k3s-node ];
in
{
  flake.modules.nixos.microvm-host = { config, lib, ... }:
    let
      clusterLib = import ../topology/_lib.nix { inherit lib; };
      nodes = clusterLib.nodesOn cluster config.networking.hostName;
    in
    {
      imports = [ inputs.microvm.nixosModules.host ];

      microvm.vms = lib.mapAttrs (name: _: {
        autostart = true;
        # A deploy does not restart changed VMs: all at once would take the whole cluster
        # down. Restart them by hand, one at a time (`systemctl restart microvm@<node>`),
        # watching the cluster in between.
        restartIfChanged = false;
        specialArgs.node = name;
        config.imports = guestModules;
      }) nodes;
    };
}
