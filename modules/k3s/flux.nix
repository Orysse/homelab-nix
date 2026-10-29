# Boundary of the base: cluster content lives in homelab-cluster (Flux).
# The Flux Operator installs and upgrades Flux from one FluxInstance, which also points it
# at the homelab-cluster repository (GitRepository and Kustomization "flux-system").
# cluster-vars exposes the topology to the manifests (${DOMAIN}, ${INGRESS_ADDRESS}…).
{ config, lib, ... }:
let
  inherit (config) cluster;
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
          url = cluster.gitops.url;
          ref = "refs/heads/${cluster.gitops.branch}";
          path = cluster.gitops.path;
        };
      };
    }];

    homelab.k3s.manifests.cluster-vars = [{
      apiVersion = "v1";
      kind = "ConfigMap";
      metadata = { name = "cluster-vars"; namespace = "flux-system"; };
      data = {
        CLUSTER_NAME = cluster.name;
        DOMAIN = cluster.ingress.domain;
        INGRESS_ADDRESS = cluster.ingress.address;
        INTERNAL_ADDRESS = cluster.ingress.internalAddress;
        LAPI_ADDRESS = cluster.ingress.lapiAddress;
        # Cilium LB-IPAM takes the range as start and stop.
        INGRESS_POOL_START = builtins.head (lib.splitString "-" cluster.ingress.pool);
        INGRESS_POOL_STOP = lib.last (lib.splitString "-" cluster.ingress.pool);
        NFS_SERVER = cluster.hosts.${cluster.storage.host}.address;
        NFS_SHARE = cluster.storage.path;
        BACKUP_ADDRESS = cluster.hosts.${cluster.backup.host}.address;
        MONITORING_ADDRESS = cluster.hosts.${cluster.monitoring.host}.address;
      };
    }];
  };
}
