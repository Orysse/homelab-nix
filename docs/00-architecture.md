# Architecture

Updated 2026-11-05 (cluster v3 on one VM per host, hosts placed through den). The earlier
three-VM layout and the NFS storage are history: decisions D29 to D33 in
`03-decisions-and-open-questions.md`.

## 1. Overview

```
LAN 192.168.1.0/24
 │
 ├── nuc1  (physical host, NixOS, br0 = host IP .200)
 │     └── microVM kube-0 (.210, k3s server)   tap attached to br0, static IP on the LAN
 │
 └── nuc2…  (future hosts: same modules, one more `hosts` entry; its VM is a k3s agent)
```

Three layers to keep separate:

| Layer    | Role                                                                      | Persistence                                                  |
| -------- | ------------------------------------------------------------------------- | ------------------------------------------------------------ |
| **host** | physical NixOS, hypervisor (`microvm.nix`), bridge, host services          | regular btrfs disk with subvolumes, **no impermanence** (D1) |
| **VM**   | one k3s node per host: cold configuration + identity share + data volumes | disposable tmpfs root, no VM image                           |
| **pod**  | k3s workloads                                                             | `local` (VM disk), `seaweedfs` (host subvolume), OpenBao (host subvolume) |

## 2. Core principle

> A VM is made of a **cold configuration** (the Nix code) given at time zero, plus
> **mounted volumes** for what is genuinely stateful.
> Killing VM A and starting VM B from the same definition should just "restart the services".

- No VM disk image to back up or migrate; VMs live on their host and can be wiped on restart.
- ✅ In microvm.nix a guest's root is already a tmpfs. The host's `/nix/store` is shared
  read-only (virtiofs). No writable store overlay: VMs do not build.
- What a VM keeps: its identity (SSH host keys, flux age key: `/persist`, D4), the k3s data
  volume (`/var/lib/rancher`, D9), the local volume for PersistentVolumes
  (`/var/lib/local-volumes`), and two host subvolumes shared by virtiofs:
  `/var/lib/seaweed` (SeaweedFS data) and `/var/lib/openbao` (OpenBao).

## 3. Data model: hosts are hardware, workloads say where they run

One file, `modules/topology/topology.nix` (schema in `options.nix`, derivations in
`_lib.nix`, checks in `assertions.nix`):

```nix
hosts.nuc1 = { id = 0; ram = 16384; cores = 12; };     # hardware only
clusters.homelab = { servers = [ "nuc1" ]; gitops.url = …; oidc = …; ingress = …; };
services = { vpn.on = "nuc1"; monitoring.on = "nuc1"; backup.on = "nuc1"; scanner.on = [ "nuc1" ]; };
```

- **Derived, not written**: host address `.20<id>`, k3s VM `kube-<id>` at `.21<id>`, MAC and
  tap from the name, the VM's memory (host RAM minus the reserves of what runs on the host,
  rounded down to 64 MB; below the floor, `nix flake check` fails), the k3s role (servers
  listed, every other host an agent), the join address and the firewall source lists.
- **den** (`modules/den/`, ADR in D30) turns the topology into entities: one host per
  `hosts` entry, its VM as a guest, and the host services placed by `services.<s>.on`. The
  building blocks stay `flake.modules.nixos.*`; den only composes them (aspects `homelab-host`,
  `vpn`, `monitoring`, `backup`, `scanner`, `k3s-node`).
- Adding a host is data: `docs/runbooks/add-host.md`.

## 4. Network

- A `br0` bridge (systemd-networkd): the wired NIC and the VMs' taps are on it; the host IP
  is carried by `br0`. VMs are directly on the LAN with static IPs outside the router's DHCP
  range, so VMs on different hosts reach each other without routing.
- Guest side: match the interface by its derived MAC, not `Type = "ether"` (the pods' veths
  would match), D13. IPv6 router advertisements are off in the VMs.
- Cluster network: Cilium (native routing, kube-proxy replacement, WireGuard between nodes,
  L2 announcements, Gateway API), D27, D28. Entry points: `.240` public Gateway, `.241`
  internal Gateway.

## 5. Storage

| Data | Where |
|---|---|
| PostgreSQL (apps, SeaweedFS filer metadata) | CloudNativePG, class `local` (VM `local.img`, preallocated) |
| SQLite and small app state | class `local` |
| Bulk files (music) | StorageClass `seaweedfs`: SeaweedFS, data on host subvolume `@seaweed` |
| OpenBao | host subvolume `@openbao`, hourly btrbk snapshots, daily offsite copy |
| Backups | Garage (S3) on the backup host, daily encrypted copy to Cloudflare R2 (D31) |

No NFS, no PostgreSQL on the host any more (D32). Replication is not a backup: SeaweedFS runs
without replication, the music is re-fetched.

## 6. Explicitly ruled out

- Terraform for the cluster; Proxmox/libvirt/KubeVirt.
- Zero downtime when moving a role.
- Replicated block storage (Longhorn, Ceph, DRBD) and pooled storage over NFS: see the
  alternatives in `InfraVC/homelab-v3-hosts-storage.md` (outside this repository).
