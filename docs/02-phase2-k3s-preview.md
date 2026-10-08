# Phase 2 — k3s preview

> Historical: written before phase 2 so that phase 1 choices would not close any doors.
> Most of it is now implemented (k3s, sops, Datadog, Flux); see the decisions document.

## Direction

- k3s on the microVMs: `kube-1` as server, `kube-2`/`kube-3` as agents (the topology `role` selects the module). Agents join via `https://<kube-1 ip>:6443`.
- Eventually several HA control planes (etcd, an **odd** number of servers) spread across several hosts. "Moving the control plane" = bringing up a new server elsewhere, letting it sync, then removing the old one cleanly (etcd snapshot first) — never migrating a VM.
- Manifests: k3s automatically applies those in `/var/lib/rancher/k3s/server/manifests/`; they can be generated from Nix. `kubenix` remains a convenience option, not a necessity.

## Points that already depend on phase 1

- **Secrets**: the k3s token must never be in plaintext → sops-nix (or equivalent) to introduce at the very start of phase 2. The VMs' SSH identity (D4) could then move to secrets instead of a persistent share.
- **Longhorn on NixOS**: known friction (Longhorn expects FHS binaries and paths — iscsiadm, nsenter… — absent from NixOS; `services.openiscsi` and probably PATH workarounds will be needed). To research before committing.
- **Per-node storage**: one data volume per VM for `/var/lib/longhorn`. The total size × 3 replicas must fit on the NVMe.
- **Backup**: target = Synology NAS (NFS or S3 depending on the model). Reasonable interval, no continuous load. Reminder: replication ≠ backup, especially with a single physical host.
- **etcd**: persistent (hence on a volume) or rebuilt from the declared manifests? (see D9).
- **RAM**: tight budget with Longhorn + the Datadog agent (see the phase 1 document).
- **Datadog**: DaemonSet in k3s, agent on the NixOS hosts as well, Longhorn metrics scraping, API server/etcd/scheduler monitoring; all configuration (checks, tags) declared in code, not in the UI.
- Ingress: Traefik shipped with k3s, not to be disabled without reason; cert-manager for HTTPS exposure.
