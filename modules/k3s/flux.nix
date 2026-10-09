# Boundary of the base: cluster content lives in homelab-cluster (Flux).
# cluster-vars exposes the topology to the manifests (${DOMAIN}, ${INGRESS_ADDRESS}…).
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.k3s-bootstrap = {
    services.k3s.autoDeployCharts.flux2 = {
      repo = "https://fluxcd-community.github.io/helm-charts";
      name = "flux2";
      version = "2.19.1"; # Flux 2.9.5
      hash = "sha256-uviFPpOhBkaZa3mePVmvY+m+HaupXV3PZh8yHNX/ppI=";
      targetNamespace = "flux-system";
      createNamespace = true;
      values = {
        imageAutomationController.create = false;
        imageReflectionController.create = false;
      };
    };

    homelab.k3s.manifests.flux-sync = [
      {
        apiVersion = "source.toolkit.fluxcd.io/v1";
        kind = "GitRepository";
        metadata = { name = "homelab-cluster"; namespace = "flux-system"; };
        spec = {
          interval = "1m";
          url = cluster.gitops.url;
          ref.branch = cluster.gitops.branch;
        };
      }
      {
        apiVersion = "kustomize.toolkit.fluxcd.io/v1";
        kind = "Kustomization";
        metadata = { name = "cluster"; namespace = "flux-system"; };
        spec = {
          interval = "10m";
          sourceRef = { kind = "GitRepository"; name = "homelab-cluster"; };
          path = cluster.gitops.path;
          prune = true;
        };
      }
    ];

    homelab.k3s.manifests.cluster-vars = [{
      apiVersion = "v1";
      kind = "ConfigMap";
      metadata = { name = "cluster-vars"; namespace = "flux-system"; };
      data = {
        CLUSTER_NAME = cluster.name;
        DD_SITE = cluster.datadog.site;
        DOMAIN = cluster.ingress.domain;
        INGRESS_ADDRESS = cluster.ingress.address;
        INTERNAL_ADDRESS = cluster.ingress.internalAddress;
        INGRESS_POOL = cluster.ingress.pool;
        NFS_SERVER = cluster.hosts.${cluster.storage.host}.address;
        NFS_SHARE = cluster.storage.path;
        MONITORING_ADDRESS = cluster.hosts.${cluster.monitoring.host}.address;
      };
    }];
  };
}
