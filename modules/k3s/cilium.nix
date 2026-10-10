# Cilium: the cluster network (CNI) instead of k3s's flannel, and kube-proxy's replacement
# (services in eBPF). In the base, not in homelab-cluster: Flux itself needs a network to
# run. Applied by k3s's Helm controller as a "bootstrap" chart (host network, before any
# node is Ready); upgraded the same way, by changing the version here.
#   routing      native: the nodes share a LAN, pod routes go straight between them
#   encryption   WireGuard between nodes (pod traffic never crosses the LAN in clear)
#   Hubble       flow visibility; UI and metrics exposed by homelab-cluster
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.k3s-bootstrap = { lib, ... }:
    let
      clusterLib = import ../topology/_lib.nix { inherit lib; };
      bootstrap = clusterLib.bootstrapServer cluster;
    in
    {
      services.k3s.autoDeployCharts.cilium = {
        repo = "https://helm.cilium.io";
        name = "cilium";
        version = "1.20.2";
        hash = "sha256-sq/Ye391+HX5KhRVnxT1m3uru0edlo4/1iWiC/MOwg4=";
        targetNamespace = "kube-system";
        # Runs on the host network and before the nodes are Ready (no CNI yet).
        extraFieldDefinitions.spec.bootstrap = true;
        values = {
          # No kube-proxy: Cilium reaches the API server directly, not through its Service.
          kubeProxyReplacement = true;
          k8sServiceHost = clusterLib.endpointOf bootstrap cluster.nodes.${bootstrap};
          k8sServicePort = 6443;

          ipam.mode = "kubernetes";              # the node pod CIDRs k3s assigns (10.42.x.0/24)
          routingMode = "native";
          ipv4NativeRoutingCIDR = "10.42.0.0/16"; # k3s's default cluster CIDR
          autoDirectNodeRoutes = true;
          bpf.masquerade = true;

          encryption = { enabled = true; type = "wireguard"; };

          # k3s keeps its CNI files in its own directories.
          cni = {
            binPath = "/var/lib/rancher/k3s/data/cni";
            confPath = "/var/lib/rancher/k3s/agent/etc/cni/net.d";
          };

          operator.replicas = 1;                 # one server
          prometheus.enabled = true;             # agent metrics (annotated, scraped by Alloy)
          operator.prometheus.enabled = true;
          hubble = {
            enabled = true;
            relay.enabled = true;
            ui.enabled = true;
            metrics.enabled = [ "dns" "drop" "tcp" "flow" "icmp" "port-distribution" ];
          };
        };
      };
    };
}
