# Base commune des invités. Paramétrée par le nom du nœud via `_module.args.node`.
{ config, ... }:
let
  inherit (config) cluster;
  topModules = config.flake.modules.nixos;
in
{
  flake.modules.nixos.microvm-guest = { lib, node, ... }:
    let
      clusterLib = import ../cluster/_lib.nix { inherit lib; };
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
          # Identité (clés SSH d'hôte). Source côté host créée par le module host microvm.
          {
            source = "/var/lib/microvms/${node}/persist";
            mountPoint = "/persist";
            tag = "persist";
            proto = "virtiofs";
          }
        ];
        # Root = tmpfs par défaut, aucun volume, pas de writableStoreOverlay.
      };

      services.openssh.hostKeys = [{
        path = "/persist/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }];

      networking.useNetworkd = true;
      networking.useDHCP = false;
      systemd.network.enable = true;
      systemd.network.networks."20-lan" = {
        # Par MAC (dérivée, donc connue) et pas par Type = "ether" : les veth des pods
        # sont aussi "ether" et networkd leur collerait l'IP du nœud.
        matchConfig.MACAddress = clusterLib.macOf node;
        # Pas d'IPv6 globale (SLAAC de la box) : k3s la choisirait comme IP de nœud,
        # et le préfixe opérateur peut changer. Le lien local IPv6 reste.
        networkConfig = clusterLib.lanNetworkConfig cluster spec.address // {
          IPv6AcceptRA = false;
        };
      };

      services.resolved.settings.Resolve.MulticastDNS = "yes";
      networking.firewall.allowedUDPPorts = [ 5353 ];

      # Interfaces créées par le CNI : laissées à k3s/flannel.
      systemd.network.networks."19-cni-unmanaged" = {
        matchConfig.Name = [ "veth*" "cni0" "flannel*" ];
        linkConfig.Unmanaged = true;
      };
    };
}
