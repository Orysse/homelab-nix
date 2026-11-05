# homelab-nix

The homelab **base**: NixOS hosts (NUCs), each running one k3s node in a microVM
([microvm.nix](https://github.com/microvm-nix/microvm.nix)); today nuc1 and its VM `kube-0`.
Everything is declared in this flake. A VM has no disk image: it is rebuilt from code
(tmpfs root); what must survive lives on volumes and host subvolumes.

This repository stops at a running k3s cluster with Flux installed. **What runs inside it**
(platform and apps) lives in the `homelab-cluster` repository, applied by Flux (GitOps). The
base hands it the network parameters through the `cluster-vars` ConfigMap (see
`docs/04-workloads.md`).

## Layers

```
 LAN 192.168.1.0/24
   │
   ├── nuc1  192.168.1.200          NixOS · br0 · microvm.nix          modules/host, modules/vm
   │     └── kube-0  .210  server   ── k3s                             modules/k3s
   │
   └── 192.168.1.240 / .241         Gateways (Cilium): public / internal
```

| Layer                            | Tool                  | Where                 |
| -------------------------------- | --------------------- | --------------------- |
| Machines: host, VMs, k3s         | Nix (deploy-rs)       | this repository       |
| Cluster content: platform, apps  | Flux (git push)       | `homelab-cluster`     |
| Application code (e.g. the site) | CI -> image           | each app's repository |

## Layout

```
flake.nix                  minimal: import-tree ./modules (dendritic pattern, flake-parts)
hardware/nuc1.nix          from nixos-generate-config (outside modules/: not a flake-parts module)
secrets/nuc1.yaml          host secrets, encrypted with sops (see .sops.yaml)
modules/
├─ topology/topology.nix   THE source of truth: network, hosts (hardware), cluster, where services run
├─ topology/               its schema (options.nix), helpers (_lib.nix), checks (assertions.nix)
├─ den/                    the topology turned into hosts and their k3s VM guests (den)
├─ hosts/<host>.nix        a host's hardware quirks only (disk, NIC)
├─ host/                   physical host modules: disk, boot, ssh, bridge, secrets, snapshots, DDNS,
│                          telemetry, monitoring, alerting, Garage + offsite copy, WireGuard, Tailscale
├─ vm/                     the k3s VM guest base (microvm-guest.nix)
└─ k3s/                    k3s node (server/agent role), token, Flux bootstrap
docs/
├─ 00-architecture.md      principles, layers, topology, storage
├─ 03-decisions-…md        decisions (Dn) and open questions
├─ 04-workloads.md         base / GitOps boundary (Flux, cluster-vars)
├─ runbooks/               bootstrap from an empty disk, add a host, lose a host
└─ facts.md                hardware, network, addressing
```

Each file under `modules/` is a flake-parts module declaring a `flake.modules.nixos.<name>`
building block; den composes them per host (`den/hosts.nix`). Files prefixed with `_` are helpers
ignored by import-tree.

## Commands

```bash
nix flake check                                                         # evaluation + topology tests
nix build .#nixosConfigurations.nuc1.config.system.build.toplevel       # full build (host + VMs)
nix run .#deploy-rs -- .#nuc1                                           # deploy (auto rollback)
ssh root@192.168.1.210 k3s kubectl get nodes                            # cluster status
```

A new host, a changed IP or RAM, or moving a service to another host is a change in
`modules/topology/topology.nix` (`docs/runbooks/add-host.md`).

## Updates

Renovate opens a pull request every Monday morning with the new `flake.lock` (nixpkgs and
the other inputs), plus one for the GitHub Actions. CI (`.github/workflows/check.yml`) runs
`nix flake check` on it, which builds the whole host. Merge it, then deploy:

```bash
git pull && nix run .#deploy-rs -- .#nuc1     # rolls back on its own if nuc1 stops answering
```

Two versions are pinned on purpose and move only by hand: Kubernetes (`pkgs.k3s_1_36` in
`modules/k3s/node.nix`, one minor version at a time) and PostgreSQL (the CloudNativePG image tag in `homelab-cluster`, a major version needs a data
migration). Cluster content
(charts, images) is updated in `homelab-cluster`.
