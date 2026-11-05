# Runbook: add a host (a new NUC)

Status: **written from the code; not rehearsed.** The first real NUC is the rehearsal: fix
this file as you go.

A host is hardware. Its k3s VM joins the existing cluster as an agent, the monitoring host
scrapes it, and its disk adds a SeaweedFS volume server (see the last section: the volume
server is a StatefulSet today, which is *not* one per node).

## What the code derives for you

From one `hosts` entry: the host address (`.20<id>`), the VM `kube-<id>` (`.21<id>`), its MAC
and tap name, its memory (the host's RAM minus the reserves, rounded down to 64 MB), the k3s
join address, the firewall rules (monitoring host to the exporters, VMs to the services) and
the deploy-rs node. `nix flake check` fails if an id or address is duplicated, the id is
outside 0..9, the VM's memory would fall under the floor (6912 MB), or a service names an
unknown host.

## Steps

1. **Hardware file.** Boot the NUC from a NixOS installer, then on it
   `nixos-generate-config --show-hardware-config`, saved as `hardware/<name>.nix` (outside
   `modules/`: not a flake-parts module). Note the disk's `/dev/disk/by-id/...` and the
   wired interface name.
2. **Host aspect.** `modules/hosts/<name>.nix`, copy of `nuc1.nix` without the nuc1 quirks:
   `imports = [ ../../hardware/<name>.nix ]`, `networking.hostName`, `homelab.diskDevice`,
   `homelab.lanInterface`.
3. **Topology.** One entry in `modules/topology/topology.nix`:
   `hosts.<name> = { id = <1..9>; ram = <MB>; cores = <n>; };` (`dataDisk` and `localDisk`
   have defaults). It becomes an agent: `clusters.homelab.agents = null` means every host
   that is not a server.
4. **SSH host key**, generated before the install so its recipient is known:
   `ssh-keygen -t ed25519 -N "" -f $d/etc/ssh/ssh_host_ed25519_key`.
5. **Age recipient.** `ssh-to-age < $d/etc/ssh/ssh_host_ed25519_key.pub`; add it to
   `.sops.yaml` as `&<name>` and to the `secrets/cluster\.yaml$` rule (the k3s token), plus
   a rule for `secrets/<name>\.yaml$`.
6. **`sops updatekeys secrets/cluster.yaml`** (the shared k3s token).
7. **`secrets/<name>.yaml`** (not in the design's six steps; found while writing this
   runbook): every k3s host runs the CrowdSec firewall bouncer, which reads
   `crowdsec-bouncer-key` from the host's own sops file. Create it with the same key as
   `secrets/nuc1.yaml` (the one in OpenBao at `kv/apps/crowdsec/bouncer`), then
   `sops updatekeys` it. (Cleaner: move the key into `cluster.yaml` and point
   `crowdsec-bouncer.nix` at it; do that at the same time if you like.)
8. **Check**: `nix flake check`, then
   `nix build .#nixosConfigurations.<name>.config.system.build.toplevel`.
9. **Install** (wipes the NUC's disk): `nixos-anywhere --flake .#<name> --extra-files $d
   --target-host root@<installer IP>`, then `nix run .#deploy-rs -- .#<name>`.
   Deploy nuc1 too: the monitoring host gains a scrape target and a firewall rule.

## Checks

- `kubectl get nodes`: `kube-<id>` Ready (agent) within 5 minutes.
- VictoriaMetrics scrapes the host: `up{host="<name>"}` is 1 for `node` and `smartctl`.
- A pod on each node reaches the other (Cilium): for instance a throwaway pod on each,
  with `kubectl run ... --overrides '{"spec":{"nodeName":"kube-<id>"}}'`.

## Afterwards

- **Re-measure the monitoring reserve** (`reserves.monitoringPerHost` in
  `modules/topology/_lib.nix`, 128 MB per host, an estimate): VictoriaMetrics' memory on
  the monitoring host before and after, recorded in `homelab-cluster/docs/measurements.md`.
  The derived VM memory on nuc1 shrinks by that much: adding a host restarts nuc1's VM when
  it is next restarted by hand, so plan that (it is the only server).
- **Storage.** A new host's disk is not in the SeaweedFS pool yet: the chart runs one
  volume server (StatefulSet, one replica). Replace it with a DaemonSet of our own
  (`infrastructure/storage/seaweedfs.yaml` has the note), with `-minFreeSpace` from the
  host's own `btrfs filesystem usage`, before relying on it. Count the host's usable
  space: its disk minus the OS, VM images, the floor and vacuum headroom.
- **CNPG, OpenBao and the filer** stay on the server host (`@openbao` is a host path on the
  control-plane node). Their pinning (node affinity on the control-plane label) is not done
  for the CNPG cluster yet: add it when the second node joins, it restarts the database once.
