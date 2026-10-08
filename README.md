# homelab-nix

The homelab **base**: a NUC running NixOS that hosts three microVMs
([microvm.nix](https://github.com/microvm-nix/microvm.nix)) forming a k3s cluster.
Everything is declared in this flake. A VM has no disk image: it is rebuilt from code
(tmpfs root), and only k3s data survives, on a volume.

This repository stops at a running k3s cluster with Flux installed. **What runs inside it**
(platform and apps) lives in the `homelab-cluster` repository, applied by Flux (GitOps). The
base hands it the network parameters through the `cluster-vars` ConfigMap (see
`docs/04-workloads.md`).

## Layers

```
 LAN 192.168.1.0/24
   │
   ├── nuc1  192.168.1.200          NixOS · br0 · microvm.nix          modules/host, modules/vm
   │     ├── kube-1  .211  server   ┐
   │     ├── kube-2  .212  agent    ├─ k3s                             modules/k3s
   │     └── kube-3  .213  agent    ┘
   │
   └── 192.168.1.240                HTTP(S) entry point: MetalLB -> Traefik
```

| Layer                            | Tool                  | Where                 |
| -------------------------------- | --------------------- | --------------------- |
| Machines: host, VMs, k3s         | Nix (`nixos-rebuild`) | this repository       |
| Cluster content: platform, apps  | Flux (git push)       | `homelab-cluster`     |
| Application code (e.g. the site) | CI -> image           | each app's repository |

## Layout

```
flake.nix                  minimal: import-tree ./modules (dendritic pattern, flake-parts)
hardware/nuc1.nix          from nixos-generate-config (outside modules/: not a flake-parts module)
secrets/nuc1.yaml          host secrets, encrypted with sops (see .sops.yaml)
modules/
├─ topology/topology.nix   THE source of truth: network, hosts, nodes, entry point, VPN
├─ topology/               its schema (options.nix), helpers (_lib.nix), checks (assertions.nix)
├─ host/                   physical host modules: disk, boot, ssh, bridge, secrets, VPN, DDNS, Datadog
├─ vm/                     microVMs generated from the topology (host side + guest base)
├─ k3s/                    k3s node (server/agent role), token, Flux bootstrap
└─ machines/nuc1.nix       composition of a physical host: which modules, which disk, which NIC
docs/
├─ 00-architecture.md      principles
├─ 03-decisions-…md        decisions (Dn) and open questions
├─ 04-workloads.md         base / GitOps boundary (Flux, cluster-vars)
└─ facts.md                hardware, network, addressing
```

Each file under `modules/` is a flake-parts module declaring a `flake.modules.nixos.<name>`
building block; `machines/<host>.nix` composes them. Files prefixed with `_` are helpers
ignored by import-tree.

## Commands

```bash
nix flake check                                                         # evaluation + topology tests
nix build .#nixosConfigurations.nuc1.config.system.build.toplevel       # full build (host + VMs)
nixos-rebuild switch --flake .#nuc1 --target-host root@192.168.1.200     # deploy
ssh root@192.168.1.211 k3s kubectl get nodes                            # cluster status
```

Changing an IP, a node's RAM, or moving a node to another host is a one-line change in
`modules/topology/topology.nix`.
