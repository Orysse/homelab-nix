# Cluster content: base / GitOps boundary

This repository (the base) stops at a running k3s cluster with **Flux installed**. Everything
that runs inside the cluster — MetalLB, Traefik configuration, cert-manager, storage class, monitoring collectors and Grafana, apps —
lives in the `homelab-cluster` repository and is applied by Flux on every `git push`.

Reason (D14): manifests declared in Nix are part of the `kube-1` VM configuration; every app
change rebuilt and **restarted the control plane**. Nix manages the machines, Flux manages
the content.

## What the base declares (modules/k3s/)

| File | Role |
|---|---|
| `flux.nix` | pinned `flux2` Helm chart (version + hash), `GitRepository` + `Kustomization` pointing to `cluster.gitops`, `cluster-vars` ConfigMap |
| `flux-sops.nix` | Flux's dedicated sops (age) key, generated once on kube-1 in `/persist` |
| `manifests.nix` | `homelab.k3s.manifests.<name>` -> `<name>.json` in k3s's manifests directory; removes manifests that are no longer declared when k3s starts |
| `node.nix` | server/agent role, data volume, `servicelb` disabled (replaced by MetalLB) |

All of it is applied by the bootstrap server (`kube-1`) only.

## The bridge: cluster-vars

The network stays defined once, in `modules/topology/topology.nix`. The base publishes the
values the cluster needs in `flux-system/cluster-vars`, which Flux substitutes:

| Topology | Variable in homelab-cluster |
|---|---|
| `cluster.name` | `${CLUSTER_NAME}` |
| `cluster.ingress.domain` | `${DOMAIN}` |
| `cluster.ingress.address` | `${INGRESS_ADDRESS}` |
| `cluster.ingress.pool` | `${INGRESS_POOL}` |
| `cluster.ingress.internalAddress` | `${INTERNAL_ADDRESS}` |
| `cluster.hosts.<storage.host>.address`, `cluster.storage.path` | `${NFS_SERVER}`, `${NFS_SHARE}` |
| `cluster.hosts.<monitoring.host>.address` | `${MONITORING_ADDRESS}` |

Changing the domain = one line in the topology + `nixos-rebuild`.

## Why JSON (manifests.nix)

`services.k3s.manifests.<x>.content` is written as YAML by the nixpkgs module, whose generator
folds long strings in the middle of escape sequences (`\\` -> `\ \`, seen in a ConfigMap's
content). Our manifests are written as JSON: nothing is folded.

## Adding an app

In `homelab-cluster` (see its README), not here.
