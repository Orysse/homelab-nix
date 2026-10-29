# Cilium: the cluster network (CNI) instead of k3s's flannel, and kube-proxy's replacement
# (services in eBPF). In the base, not in homelab-cluster: Flux itself needs a network to
# run. Applied by k3s's Helm controller as a "bootstrap" chart (host network, before any
# node is Ready); upgraded the same way, by changing the version here.
#   routing      native: the nodes share a LAN, pod routes go straight between them
#   encryption   WireGuard between nodes (pod traffic never crosses the LAN in clear)
#   Hubble       flow visibility; UI and metrics exposed by homelab-cluster
#   LB IPs       LoadBalancer addresses from a pool, announced on the LAN (ARP)
#   Gateway API  served by the Envoy Cilium already runs on each node (no ingress controller)
# The pools, the Gateway and its access log format live in homelab-cluster (ADR 0002, 0003).
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

          # CNI files in the standard paths (/etc/cni/net.d, /opt/cni/bin): with flannel off,
          # k3s points containerd there, not at its own directories. On the VMs' tmpfs root;
          # Cilium writes them again at every start.

          operator.replicas = 1;                 # one server
          prometheus.enabled = true;             # agent metrics (annotated, scraped by the OTel Collector)
          operator.prometheus.enabled = true;
          hubble = {
            enabled = true;
            relay.enabled = true;
            ui.enabled = true;
            metrics.enabled = [ "dns" "drop" "tcp" "flow" "icmp" "port-distribution" ];
          };

          # Both stay idle until a CiliumLoadBalancerIPPool / Gateway of class "cilium" exists.
          # After enabling gatewayAPI on a running cluster, restart cilium-operator: it can
          # start before cilium-config is updated and never register the Envoy CRDs (ADR 0002).
          l2announcements.enabled = true;
          # L2 announcements hold one lease per Service: the docs ask for a higher client rate.
          k8sClientRateLimit = { qps = 20; burst = 40; };
          gatewayAPI.enabled = true;
        };
      };
    };
}
