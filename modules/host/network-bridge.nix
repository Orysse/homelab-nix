{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.network-bridge = { config, lib, ... }:
  let
    clusterLib = import ../topology/_lib.nix { inherit lib; };
  in
  {
    options.homelab.lanInterface = lib.mkOption {
      type = lib.types.str;
      description = "NIC filaire du host, esclave de br0.";
    };

    config = {
      networking.useNetworkd = true;
      networking.useDHCP = false;
      systemd.network.enable = true;

      systemd.network.netdevs."10-br0".netdevConfig = {
        Name = "br0";
        Kind = "bridge";
      };

      systemd.network.networks."10-lan" = {
        matchConfig.Name = [ config.homelab.lanInterface "vm-*" ];
        networkConfig.Bridge = "br0";
      };

      systemd.network.networks."10-br0" = {
        matchConfig.Name = "br0";
        networkConfig = clusterLib.lanNetworkConfig cluster
          cluster.hosts.${config.networking.hostName}.address;
        linkConfig.RequiredForOnline = "routable";
      };

      services.resolved.settings.Resolve.MulticastDNS = "yes";

      # Ne filtre que le trafic destiné au host : le trafic ponté vers les VMs ne
      # traverse pas netfilter (pas de br_netfilter).
      networking.firewall.enable = true;
      networking.firewall.allowedUDPPorts = [ 5353 ];
    };
  };
}
