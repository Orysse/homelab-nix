# VM root on tmpfs; only /var/lib/rancher (and /etc/rancher, redirected into it) survives,
# on a disk: containerd's overlayfs does not work on virtiofs.
# Only the bootstrap server applies k3s-bootstrap: k3s does not sync its manifests.
{ config, ... }:
let
  inherit (config) cluster;
  bootstrapModule = config.flake.modules.nixos.k3s-bootstrap;
in
{
  flake.modules.nixos.k3s-node = { lib, pkgs, node, ... }:
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
        # Kubernetes minor version, pinned: a flake update only brings its patch releases.
        # Upgrading = one minor at a time (k3s_1_37, then the next), servers before agents.
        package = pkgs.k3s_1_36;
        role = spec.role;
        tokenFile = "/persist/k3s-token";
        nodeName = node;
        nodeIP = spec.address;
        clusterInit = isServer && isBootstrap;
        # local-storage: volumes would live inside the VMs; they use NFS from the storage host.
        disable = lib.optionals isServer [ "servicelb" "local-storage" ];
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
            # On the host (/persist is a virtiofs share): survives the VM.
            "--etcd-snapshot-dir=/persist/etcd-snapshots"
            # People: OIDC tokens from Pocket-ID (structured config below, several clients).
            "--kube-apiserver-arg=authentication-config=/etc/kubernetes/authentication.yaml"
            # Who changed what through the API (policy below), into the journal, shipped to
            # VictoriaLogs (microvm-guest.nix).
            "--kube-apiserver-arg=audit-policy-file=/etc/kubernetes/audit-policy.yaml"
            "--kube-apiserver-arg=audit-log-path=-"
          ]
          ++ lib.optional (spec.address != null) "--tls-san=${spec.address}"
        );
      };

      # Kubernetes API authentication for people: ID tokens from the topology's OIDC issuer
      # (Pocket-ID), for any of its clients. Users and groups are prefixed "oidc:" so they
      # never collide with built-in ones; RBAC lives in homelab-cluster. The admin
      # kubeconfig (client certificate) keeps working if Pocket-ID is down.
      environment.etc."kubernetes/authentication.yaml" = lib.mkIf isServer {
        text = builtins.toJSON {
          apiVersion = "apiserver.config.k8s.io/v1";
          kind = "AuthenticationConfiguration";
          # k3s disables anonymous auth with a flag, which it skips when a config file is
          # given: done here instead (as before, anonymous requests get 401).
          anonymous.enabled = false;
          jwt = [{
            issuer = {
              url = cluster.oidc.issuer;
              audiences = cluster.oidc.audiences;
              audienceMatchPolicy = "MatchAny";
            };
            claimMappings = {
              username = { claim = "preferred_username"; prefix = "oidc:"; };
              groups = { claim = "groups"; prefix = "oidc:"; };
            };
          }];
        };
      };

      # API audit: what people do (OIDC users, the admin certificate), never what the
      # machines do (controllers, nodes, Flux and every other service account). Changes are
      # logged (who, what, when, from where, result), reads are not, except secrets and
      # config maps: who read them. Content is never logged (Metadata level).
      environment.etc."kubernetes/audit-policy.yaml" = lib.mkIf isServer {
        text = builtins.toJSON {
          apiVersion = "audit.k8s.io/v1";
          kind = "Policy";
          omitStages = [ "RequestReceived" ];
          rules = [
            { level = "None"; userGroups = [ "system:serviceaccounts" "system:nodes" ]; }
            { level = "None"; users = [
                "system:kube-controller-manager" "system:kube-scheduler" "system:kube-proxy"
                "system:apiserver" "system:k3s-controller" "system:cloud-controller-manager"
              ]; }
            { level = "Metadata"; resources = [{ group = ""; resources = [ "secrets" "configmaps" ]; }]; }
            { level = "None"; verbs = [ "get" "list" "watch" ]; }
            { level = "None"; nonResourceURLs = [ "/*" ]; }
            { level = "Metadata"; }
          ];
        };
      };

      # Volumes are NFS mounts from the storage host (csi-driver-nfs mounts through this kernel).
      boot.supportedFilesystems = [ "nfs" ];

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
