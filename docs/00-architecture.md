# Architecture

Legend: ✅ = verified against upstream documentation/code on 2026-10-07.

## 1. Overview

```
LAN 192.168.1.0/24
 │
 ├── nuc1  (physical host, NixOS, br0 = host IP)
 │     ├── microVM kube-1   ─┐
 │     ├── microVM kube-2    ├─ vm-* taps attached to br0, static IPs on the LAN
 │     └── microVM kube-3   ─┘
 │
 └── nuc2…  (future hosts: same model, same modules, one more entry in the topology)
```

Three layers to keep separate:

| Layer | Role | Persistence |
|---|---|---|
| **host** | physical NixOS, hypervisor (`microvm.nix`), bridge | regular btrfs disk with subvolumes, **no impermanence** (D1) |
| **VM** | a "node": cold configuration + a small identity share + a k3s data volume | disposable tmpfs root, no VM image |
| **pod** | k3s workloads | stateful data in PVCs |

## 2. Core principle

> A VM is made of a **cold configuration** (the Nix code) given at time zero, plus
> **mounted volumes** for what is genuinely stateful.
> Killing VM A and starting VM B from the same definition should just "restart the services".

Consequences:

- No VM disk image to back up or migrate. VMs live on their host and can be wiped on restart.
- ✅ In microvm.nix, a guest's root is **already a tmpfs** by default (`fsType = "tmpfs"`, `size=50%`): there is nothing to configure for impermanence *inside* the VM.
- ✅ The host's `/nix/store` is shared read-only with the guest (virtiofs share), which avoids a large squashfs image.
- A **writable store overlay** is not needed: VMs do not run `nix build`, they are rebuilt by the host. ✅ It would require a *volume* anyway (9p/virtiofs shares do not work with overlayfs). **We do not use one.**
- The state tolerated for a VM is a small **identity** (SSH host keys, D4) and the **k3s data volume** (D9).

## 3. Data model: the topology is data

This is the key piece for "if I change the code, the control plane is there and no longer
where it was".

A single file, `modules/topology/topology.nix`, describes what runs where:

```nix
cluster = {
  network = { subnet = "192.168.1.0"; prefixLength = 24; gateway = "192.168.1.1"; dns = [ "192.168.1.1" ]; };
  hosts = {
    nuc1.address = "192.168.1.200";
    # nuc2.address = "192.168.1.201";   # future
  };
  nodes = {
    kube-1 = { host = "nuc1"; address = "192.168.1.211"; role = "server"; mem = 4000; vcpu = 2; };
    kube-2 = { host = "nuc1"; address = "192.168.1.212"; role = "agent";  mem = 3000; vcpu = 2; };
    kube-3 = { host = "nuc1"; address = "192.168.1.213"; role = "agent";  mem = 3000; vcpu = 2; };
  };
};
```

Rules:

- Each host module **generates its `microvm.vms`** from the `nodes` whose `host == <this host>`. No VM is written by hand in a host file.
- `node.host` is a scalar: a node therefore **cannot** be on two hosts at once, by construction.
- MAC and tap names are **derived** from the node name (deterministic). ✅ Upstream constraints: MAC of the form `02:00:00:…`; tap id `vm-*` (the pattern the bridge matches). A Linux interface name is ≤ 15 characters → **node name ≤ 12 characters** (assertion).
- Evaluation-time assertions: unique IPs, IPs inside the subnet, unique MACs, `host` refers to an existing host, name length, at least one server.
- `role` selects the k3s role (server/agent); the first server initializes etcd.

## 4. Network

- ✅ Upstream model: a `br0` bridge managed by systemd-networkd; the physical Ethernet interface **and** the `vm-*` taps are attached to `br0`; the host IP is carried by `br0`.
- VMs are therefore **directly on the LAN** with static IPs (outside the router's DHCP range). This lets VMs on different hosts reach each other without extra routing.
- Constraint: the host interface must be **wired** (bridging over Wi-Fi does not work).
- ✅ On the guest side, match the interface by its **derived MAC** (`matchConfig.MACAddress`), not by `Type = "ether"`, which also matches the k3s pods' veths (D13), nor by a name such as `eth0`.
- flannel/vxlan (UDP 8472) from k3s provides the pod network on top.

## 5. Storage

- **Host**: no impermanence. Single NVMe: 1 GB ESP + btrfs with subvolumes `@root`, `@nix`, `@log`, `@microvms` (see `modules/host/disk-layout.nix`). No LUKS for now (see D2).
- **VM**: a small identity share (D4) and one ext4 data volume per VM for `/var/lib/rancher` (D9).
- **Application data**: replicated storage (e.g. Longhorn) only makes sense with several physical hosts. With a single host, all replicas sit on the same disk: **replication is not a backup**. The planned backup target is the owner's Synology NAS, at a reasonable interval.

## 6. Explicitly ruled out

- Terraform for the cluster; Proxmox/libvirt/KubeVirt.
- Zero downtime when moving a role.
- "Same disk / same network visible from anywhere" in the strong sense: only IP connectivity between VMs and distributed storage for application data are required.
