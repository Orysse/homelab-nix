# br0 porte l'IP du host ; la NIC filaire et les taps vm-* y sont esclaves.
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

      # Statique ou DHCP selon la topologie ; mDNS dans les deux cas (<host>.local).
      systemd.network.networks."10-br0" = {
        matchConfig.Name = "br0";
        networkConfig = clusterLib.lanNetworkConfig cluster
          cluster.hosts.${config.networking.hostName}.address;
        linkConfig.RequiredForOnline = "routable";
      };

      services.resolved.settings.Resolve.MulticastDNS = "yes";

      # Le firewall du host ne filtre que ce qui lui est destiné ; le trafic ponté
      # vers les VMs n'y passe pas (pas de br_netfilter). Ouverts : SSH (users-ssh), mDNS.
      networking.firewall.enable = true;
      networking.firewall.allowedUDPPorts = [ 5353 ];
    };
  };
}
