# Brique invité : fait d'un nœud de la topologie un nœud k3s. Le `role` choisit
# server/agent ; le premier server (ordre alphabétique) initialise le datastore etcd.
#
# État : le root de la VM reste un tmpfs. Seul l'état k3s survit, sur un volume de
# données par VM (/var/lib/rancher). /etc/rancher (mot de passe du nœud, kubeconfig)
# y est redirigé. Ce volume est un disque et non un partage virtiofs, car l'overlayfs
# de containerd ne fonctionne pas sur virtiofs.
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.k3s-node = { lib, node, ... }:
    let
      clusterLib = import ../cluster/_lib.nix { inherit lib; };
      spec = cluster.nodes.${node};
      bootstrap = clusterLib.bootstrapServer cluster;
      isServer = spec.role == "server";
      isBootstrap = node == bootstrap;
    in
    {
      microvm.volumes = [{
        image = "/var/lib/microvms/${node}/k3s-data.img";
        mountPoint = "/var/lib/rancher";
        size = spec.dataDisk;
        fsType = "ext4";
      }];

      systemd.tmpfiles.settings."10-k3s-etc" = {
        "/var/lib/rancher/etc".d.mode = "0755";
        "/etc/rancher"."L+".argument = "/var/lib/rancher/etc";
      };

      services.k3s = {
        enable = true;
        role = spec.role;
        # Écrit par la brique host k3s-token, partagé via /persist. Jamais dans le repo.
        tokenFile = "/persist/k3s-token";
        nodeName = node;
        # null (DHCP) : k3s prend l'IP de l'interface de la route par défaut.
        nodeIP = spec.address;
        clusterInit = isServer && isBootstrap;
        # IP statique du server si connue, sinon <server>.local (mDNS).
        serverAddr = lib.optionalString (!isBootstrap)
          "https://${clusterLib.endpointOf bootstrap cluster.nodes.${bootstrap}}:6443";
        # resolv.conf "réel" de resolved (le stub 127.0.0.53 est inutilisable dans
        # les pods ; sans ça kubelet retombe sur 8.8.8.8).
        extraFlags = [ "--resolv-conf=/run/systemd/resolve/resolv.conf" ]
          ++ lib.optionals isServer (
          [ "--tls-san=${node}.local" "--write-kubeconfig-mode=0600" ]
          ++ lib.optional (spec.address != null) "--tls-san=${spec.address}"
        );
      };

      systemd.services.k3s = {
        unitConfig.RequiresMountsFor = [ "/var/lib/rancher" "/persist" ];
        after = [ "systemd-tmpfiles-setup.service" ];
      };

      # Ports : https://docs.k3s.io/installation/requirements#inbound-rules-for-k3s-nodes
      networking.firewall = {
        allowedTCPPorts = [ 10250 80 443 ]
          ++ lib.optionals isServer [ 6443 2379 2380 ];
        allowedUDPPorts = [ 8472 ]; # flannel vxlan
        trustedInterfaces = [ "cni0" "flannel.1" ];
      };
    };
}
