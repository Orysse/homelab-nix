# `node` (specialArgs) : nom du nœud dans la topologie.
{ config, ... }:
let
  inherit (config) cluster;
  topModules = config.flake.modules.nixos;
in
{
  flake.modules.nixos.microvm-guest = { lib, node, ... }:
    let
      clusterLib = import ../topology/_lib.nix { inherit lib; };
      spec = cluster.nodes.${node};
    in
    {
      imports = [ topModules.base topModules.users-ssh ];

      networking.hostName = node;

      microvm = {
        hypervisor = "qemu";
        inherit (spec) mem vcpu;

        interfaces = [{
          type = "tap";
          id = clusterLib.tapOf node;
          mac = clusterLib.macOf node;
        }];

        shares = [
          {
            source = "/nix/store";
            mountPoint = "/nix/.ro-store";
            tag = "ro-store";
            proto = "virtiofs";
          }
          {
            source = "/var/lib/microvms/${node}/persist";
            mountPoint = "/persist";
            tag = "persist";
            proto = "virtiofs";
          }
        ];
      };

      services.openssh.hostKeys = [{
        path = "/persist/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }];

      networking.useNetworkd = true;
      networking.useDHCP = false;
      systemd.network.enable = true;
      systemd.network.networks."20-lan" = {
        # Pas Type = "ether" : les veth des pods matcheraient et recevraient l'IP du nœud.
        matchConfig.MACAddress = clusterLib.macOf node;
        # Sinon k3s prend l'IPv6 SLAAC de la box (préfixe opérateur, non stable) comme IP de nœud.
        networkConfig = clusterLib.lanNetworkConfig cluster spec.address // {
          IPv6AcceptRA = false;
        };
      };

      services.resolved.settings.Resolve.MulticastDNS = "yes";
      networking.firewall.allowedUDPPorts = [ 5353 ];

      systemd.network.networks."19-cni-unmanaged" = {
        matchConfig.Name = [ "veth*" "cni0" "flannel*" ];
        linkConfig.Unmanaged = true;
      };
    };
}
