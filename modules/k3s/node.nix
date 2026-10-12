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

      # The kernel parameters kubelet expects with --protect-kernel-defaults (it no longer sets
      # them itself, and refuses to start otherwise; the microVM boots with kernel.panic=-1).
      boot.kernel.sysctl = {
        "vm.overcommit_memory" = 1;
        "vm.panic_on_oom" = 0;
        "kernel.panic" = 10;
        "kernel.panic_on_oops" = 1;
        "kernel.keys.root_maxkeys" = 1000000;
        "kernel.keys.root_maxbytes" = 25000000;
      };

      systemd.tmpfiles.settings."10-k3s-etc" = {
        "/var/lib/rancher/etc".d.mode = "0755";
        "/etc/rancher"."L+".argument = "/var/lib/rancher/etc";
        # Kubelet config drop-in (k3s writes its own 00-k3s-defaults.conf next to it): swap
        # is allowed (zram, microvm-guest.nix). LimitedSwap: Burstable pods may swap in
        # proportion to their memory request; Guaranteed pods and system-critical ones never.
        "/var/lib/rancher/k3s/agent/etc/kubelet.conf.d".d.mode = "0700";
        "/var/lib/rancher/k3s/agent/etc/kubelet.conf.d/90-swap.conf"."L+".argument =
          toString (pkgs.writeText "kubelet-swap.conf" (builtins.toJSON {
            apiVersion = "kubelet.config.k8s.io/v1beta1";
            kind = "KubeletConfiguration";
            failSwapOn = false;
            memorySwap.swapBehavior = "LimitedSwap";
          }));
      } // lib.optionalAttrs isServer {
        # k3s does not create it, and silently skips scheduled snapshots without it.
        "/persist/etcd-snapshots".d.mode = "0700";
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
        extraFlags = [
          "--resolv-conf=/run/systemd/resolve/resolv.conf"
          # No swap in the VMs: evict pods before the kernel starts thrashing, and keep room
          # for the system (2026-10-11: nodes thrashed one after the other at ~100 MB free).
          "--kubelet-arg=system-reserved=cpu=200m,memory=300Mi"
          "--kubelet-arg=eviction-hard=memory.available<300Mi"
          # CIS hardening (k3s guide): kubelet refuses to run if the kernel parameters it
          # relies on were changed (the k3s module sets them), and idle exec/port-forward
          # sessions are cut.
          "--protect-kernel-defaults"
          "--kubelet-arg=streaming-connection-idle-timeout=5m"
        ]
          ++ lib.optionals isServer (
          [
            "--tls-san=${node}.local"
            "--write-kubeconfig-mode=0600"
            "--secrets-encryption"
            # Network and services by Cilium (cilium.nix): no flannel, no kube-proxy, no k3s
            # network policy controller.
            "--flannel-backend=none"
            "--disable-network-policy"
            "--disable-kube-proxy"
            # On the host (/persist is a virtiofs share): survives the VM.
            "--etcd-snapshot-dir=/persist/etcd-snapshots"
            # People: OIDC tokens from Pocket-ID (structured config below, several clients).
            "--kube-apiserver-arg=authentication-config=/etc/kubernetes/authentication.yaml"
            # Who changed what through the API (policy below), into the journal, shipped to
            # VictoriaLogs (microvm-guest.nix).
            "--kube-apiserver-arg=audit-policy-file=/etc/kubernetes/audit-policy.yaml"
            "--kube-apiserver-arg=audit-log-path=-"
            # Pod security for every namespace without its own label: baseline enforced,
            # restricted reported (admission config below).
            "--kube-apiserver-arg=admission-control-config-file=/etc/kubernetes/pod-security.yaml"
            # The control plane shares this node with pods: without a reservation, pods ate its
            # memory, etcd stalled and k3s lost its leases in a loop (2026-10-11). Reserve room
            # for k3s itself and steer apps to the agents (the taint is only applied when the
            # node registers: `kubectl taint` it by hand on an existing node).
            "--kubelet-arg=kube-reserved=cpu=500m,memory=1Gi"
            "--node-taint=node-role.kubernetes.io/control-plane:PreferNoSchedule"
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

      # Default pod security: a new namespace is baseline at least (no privileged pods, no host
      # namespaces or paths) unless labelled otherwise; restricted shows up as warnings and in
      # the audit log. Exempt: the namespaces whose pods need the host (Cilium, Tetragon, CSI,
      # MetalLB speakers, CrowdSec agents). monitoring is labelled privileged in
      # homelab-cluster.
      environment.etc."kubernetes/pod-security.yaml" = lib.mkIf isServer {
        text = builtins.toJSON {
          apiVersion = "apiserver.config.k8s.io/v1";
          kind = "AdmissionConfiguration";
          plugins = [{
            name = "PodSecurity";
            configuration = {
              apiVersion = "pod-security.admission.config.k8s.io/v1";
              kind = "PodSecurityConfiguration";
              defaults = {
                enforce = "baseline"; enforce-version = "latest";
                audit = "restricted"; audit-version = "latest";
                warn = "restricted"; warn-version = "latest";
              };
              exemptions = {
                usernames = [ ]; runtimeClasses = [ ];
                namespaces = [ "kube-system" "crowdsec" "metallb-system" ];
              };
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
                "system:apiserver" "system:k3s-controller" "system:k3s-supervisor"
                "system:cloud-controller-manager" "k3s-cloud-controller-manager"
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
      # Nodes only: etcd, kubelet, MetalLB memberlist (7946), Cilium health (4240), Hubble
      # peers (4244), Cilium WireGuard (51871).
      networking.firewall =
        let
          nodeIPs = lib.filter (a: a != null) (lib.mapAttrsToList (_: n: n.address) cluster.nodes);
          fromNodes = proto: port: lib.concatMapStrings
            (ip: "iptables -A nixos-fw -p ${proto} -s ${ip} --dport ${port} -j nixos-fw-accept\n")
            nodeIPs;
          # Pods on other nodes (Cilium does not NAT pod-to-node traffic): metrics-server to
          # the kubelets, hubble-relay to the Hubble agents.
          fromPods = port: "iptables -A nixos-fw -p tcp -s 10.42.0.0/16 --dport ${port} -j nixos-fw-accept\n";
        in
        {
          allowedTCPPorts = [ 80 443 ] ++ lib.optionals isServer [ 6443 ];
          extraCommands = fromNodes "tcp" "10250" + fromNodes "tcp" "7946" + fromNodes "udp" "7946"
            + fromNodes "tcp" "4240" + fromNodes "tcp" "4244" + fromNodes "udp" "51871"
            + fromPods "10250" + fromPods "4244"
            + lib.optionalString isServer (fromNodes "tcp" "2379:2380");
          # Pod-side interfaces (lxc*), Cilium's host and WireGuard devices.
          trustedInterfaces = [ "lxc+" "cilium_host" "cilium_net" "cilium_wg0" ];
          # Pod traffic arrives on interfaces whose routes point elsewhere (eBPF routing).
          checkReversePath = false;
        };
    };
}
