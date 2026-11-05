# Boundary of the base: cluster content lives in homelab-cluster (Flux).
# The Flux Operator installs and upgrades Flux from one FluxInstance, which also points it
# at the homelab-cluster repository (GitRepository and Kustomization "flux-system").
# cluster-vars exposes the topology to the manifests (${DOMAIN}, ${INGRESS_ADDRESS}…).
{ config, lib, ... }:
let
  inherit (config) cluster;
  clusterLib = import ../topology/_lib.nix { inherit lib; };
  c = clusterLib.theCluster cluster;
  address = service: clusterLib.hostAddress cluster (clusterLib.hostOf cluster service);
in
{
  flake.modules.nixos.k3s-bootstrap = {
    services.k3s.autoDeployCharts.flux-operator = {
      repo = "oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator";
      name = "flux-operator";
      version = "0.62.1";
      hash = "sha256-GTB1X1CTsljECKKLcCyXkJAoPgCLctQT9ukqSwl6uQg=";
      targetNamespace = "flux-system";
      createNamespace = true;
    };

    homelab.k3s.manifests.flux-instance = [{
      apiVersion = "fluxcd.controlplane.io/v1";
      kind = "FluxInstance";
      metadata = { name = "flux"; namespace = "flux-system"; };
      spec = {
        distribution = {
          version = "2.9.6";
          registry = "ghcr.io/fluxcd";
        };
        # No image automation: Renovate opens the version bumps as pull requests.
        components = [
          "source-controller"
          "kustomize-controller"
          "helm-controller"
          "notification-controller"
        ];
        sync = {
          kind = "GitRepository";
          url = c.gitops.url;
          ref = "refs/heads/${c.gitops.branch}";
          path = c.gitops.path;
        };
      };
    }];

    homelab.k3s.manifests.cluster-vars = [{
      apiVersion = "v1";
      kind = "ConfigMap";
      metadata = { name = "cluster-vars"; namespace = "flux-system"; };
      data = {
        CLUSTER_NAME = cluster.name;
        DOMAIN = c.ingress.domain;
        INGRESS_ADDRESS = c.ingress.address;
        INTERNAL_ADDRESS = c.ingress.internalAddress;
        LAPI_ADDRESS = c.ingress.lapiAddress;
        # Cilium LB-IPAM takes the range as start and stop.
        INGRESS_POOL_START = builtins.head (lib.splitString "-" c.ingress.pool);
        INGRESS_POOL_STOP = lib.last (lib.splitString "-" c.ingress.pool);
        BACKUP_ADDRESS = address "backup";
        MONITORING_ADDRESS = address "monitoring";
      };
    }];
  };
}
