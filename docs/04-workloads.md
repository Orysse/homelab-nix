# Cluster content: base / GitOps boundary

This repository (the base) stops at a running k3s cluster with **Flux installed**. Everything
that runs inside the cluster (Cilium's Gateways, cert-manager, storage classes, OpenBao,
Pocket-ID, Headscale, monitoring collectors and Grafana, apps) lives in the `homelab-cluster`
repository and is applied by Flux on every `git push`.

Reason (D14): manifests declared in Nix were part of the VM's configuration; every app
change rebuilt and **restarted the control plane**. Nix manages the machines, Flux manages
the content.

## What the base declares (modules/k3s/)

| File | Role |
|---|---|
| `flux.nix` | Flux Operator + a `FluxInstance` pointing to `clusters.<c>.gitops`; the `cluster-vars` ConfigMap |
| `flux-sops.nix` | Flux's dedicated sops (age) key, generated once on the bootstrap server in `/persist` |
| `cilium.nix`, `gateway-api.nix` | the network the nodes need to be Ready, installed as k3s bootstrap manifests |
| `manifests.nix` | `homelab.k3s.manifests.<name>` → `<name>.json` in k3s's manifests directory |
| `node.nix` | server/agent role, data and local volumes, kubelet and API server settings (OIDC, audit) |
| `token.nix` | the one k3s token (sops `secrets/cluster.yaml`), installed into each VM's persist |

The first server initializes etcd (`clusterInit`).

## The bridge: cluster-vars

The network stays defined once, in `modules/topology/topology.nix`. The base publishes the
values the cluster needs in `flux-system/cluster-vars`, which Flux substitutes:

| Topology | Variable in homelab-cluster |
|---|---|
| `cluster.name` | `${CLUSTER_NAME}` |
| `clusters.<c>.ingress.domain` | `${DOMAIN}` |
| `clusters.<c>.ingress.address`, `internalAddress`, `lapiAddress` | `${INGRESS_ADDRESS}`, `${INTERNAL_ADDRESS}`, `${LAPI_ADDRESS}` |
| `clusters.<c>.ingress.pool` | `${INGRESS_POOL_START}`, `${INGRESS_POOL_STOP}` |
| address of the host running `backup` | `${BACKUP_ADDRESS}` |
| address of the host running `monitoring` | `${MONITORING_ADDRESS}` |

Changing the domain = one line in the topology + a deploy.

## Why JSON (manifests.nix)

`services.k3s.manifests.<x>.content` is written as YAML by the nixpkgs module, whose generator
folds long strings in the middle of escape sequences. Our manifests are written as JSON:
nothing is folded.

## Adding an app

In `homelab-cluster` (see its README and `docs/onboarding/`), not here.
