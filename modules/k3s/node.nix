# VM root on tmpfs; only /var/lib/rancher (and /etc/rancher, redirected into it) survives,
# on a disk: containerd's overlayfs does not work on virtiofs.
# Only the bootstrap server applies k3s-bootstrap: k3s does not sync its manifests.
{ config, ... }:
let
  inherit (config) cluster;
  bootstrapModule = config.flake.modules.nixos.k3s-bootstrap;
in
{
  flake.modules.nixos.k3s-node = { lib, node, ... }:
    let
      clusterLib = import ../topology/_lib.nix { inherit lib; };
      spec = cluster.nodes.${node};
      bootstrap = clusterLib.bootstrapServer cluster;
      isServer = spec.role == "server";
      isBootstrap = node == bootstrap;
    in
    {
      imports = lib.optional isBootstrap bootstrapModule;

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
        tokenFile = "/persist/k3s-token";
        nodeName = node;
        nodeIP = spec.address;
        clusterInit = isServer && isBootstrap;
        disable = lib.optionals isServer [ "servicelb" ];
        serverAddr = lib.optionalString (!isBootstrap)
          "https://${clusterLib.endpointOf bootstrap cluster.nodes.${bootstrap}}:6443";
        # The 127.0.0.53 stub is unreachable from pods (kubelet would fall back to 8.8.8.8).
        extraFlags = [ "--resolv-conf=/run/systemd/resolve/resolv.conf" ]
          ++ lib.optionals isServer (
          [ "--tls-san=${node}.local" "--write-kubeconfig-mode=0600" "--secrets-encryption" ]
          ++ lib.optional (spec.address != null) "--tls-san=${spec.address}"
        );
      };

      systemd.services.k3s = {
        unitConfig.RequiresMountsFor = [ "/var/lib/rancher" "/persist" ];
        after = [ "systemd-tmpfiles-setup.service" ];
      };

      # https://docs.k3s.io/installation/requirements#inbound-rules-for-k3s-nodes
      networking.firewall = {
        allowedTCPPorts = [ 10250 80 443 7946 ] # 7946: MetalLB memberlist
          ++ lib.optionals isServer [ 6443 2379 2380 ];
        allowedUDPPorts = [ 8472 7946 ]; # flannel vxlan, MetalLB memberlist
        trustedInterfaces = [ "cni0" "flannel.1" ];
      };
    };
}
