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
          [
            "--tls-san=${node}.local"
            "--write-kubeconfig-mode=0600"
            "--secrets-encryption"
            # Pod traffic between nodes encrypted and authenticated (VXLAN is neither).
            "--flannel-backend=wireguard-native"
            # People log in to the API with Authelia (OIDC issuer auth.<domain>): `kubectl
            # oidc-login`. Identities are prefixed "oidc:" so they never collide with
            # built-in users; RBAC lives in homelab-cluster. The admin kubeconfig (client
            # certificate) keeps working if Authelia is down.
            "--kube-apiserver-arg=oidc-issuer-url=https://auth.${cluster.ingress.domain}"
            "--kube-apiserver-arg=oidc-client-id=kubernetes"
            "--kube-apiserver-arg=oidc-username-claim=preferred_username"
            "--kube-apiserver-arg=oidc-username-prefix=oidc:"
            "--kube-apiserver-arg=oidc-groups-claim=groups"
            "--kube-apiserver-arg=oidc-groups-prefix=oidc:"
          ]
          ++ lib.optional (spec.address != null) "--tls-san=${spec.address}"
        );
      };

      systemd.services.k3s = {
        unitConfig.RequiresMountsFor = [ "/var/lib/rancher" "/persist" ];
        after = [ "systemd-tmpfiles-setup.service" ];
      };

      # https://docs.k3s.io/installation/requirements#inbound-rules-for-k3s-nodes
      # Open to the LAN: SSH, the API (kubectl from the LAN and the VPN), Traefik.
      # Nodes only: etcd, kubelet, MetalLB memberlist (7946), flannel WireGuard (51820).
      networking.firewall =
        let
          nodeIPs = lib.filter (a: a != null) (lib.mapAttrsToList (_: n: n.address) cluster.nodes);
          fromNodes = proto: port: lib.concatMapStrings
            (ip: "iptables -A nixos-fw -p ${proto} -s ${ip} --dport ${port} -j nixos-fw-accept\n")
            nodeIPs;
        in
        {
          allowedTCPPorts = [ 80 443 ] ++ lib.optionals isServer [ 6443 ];
          extraCommands = fromNodes "tcp" "10250" + fromNodes "tcp" "7946" + fromNodes "udp" "7946"
            + fromNodes "udp" "51820"
            + lib.optionalString isServer (fromNodes "tcp" "2379:2380");
          trustedInterfaces = [ "cni0" "flannel-wg" ];
        };
    };
}
