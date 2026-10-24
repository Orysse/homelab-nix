{ config, inputs, ... }:
let
  inherit (config) cluster;
  topModules = config.flake.modules.nixos;
  nodeModules = with topModules; [ microvm-guest k3s-node ];
  devboxModules = with topModules; [ microvm-guest devbox-guest ];
in
{
  flake.modules.nixos.microvm-host = { config, lib, ... }:
    let
      clusterLib = import ../topology/_lib.nix { inherit lib; };
      hostName = config.networking.hostName;
      nodes = clusterLib.nodesOn cluster hostName;
      devboxes = clusterLib.devboxesOn cluster hostName;
      vm = modules: name: _: {
        autostart = true;
        # A deploy does not restart changed VMs: all at once would take the whole cluster
        # down. Restart them by hand, one at a time (`systemctl restart microvm@<node>`),
        # watching the cluster in between.
        restartIfChanged = false;
        specialArgs.node = name;
        config.imports = modules;
      };
    in
    {
      imports = [ inputs.microvm.nixosModules.host topModules.devbox-host ];

      microvm.vms = lib.mapAttrs (vm nodeModules) nodes // lib.mapAttrs (vm devboxModules) devboxes;
    };
}
