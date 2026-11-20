# homelab-nix — context for Claude Code

Declarative NixOS homelab: a k3s cluster running in microVMs (`microvm.nix`) on one or more
physical hosts. A personal showcase project, but the infrastructure must be sound and able
to carry a real stack. The owner is also preparing an interview at Datadog.

**Reply in the language the owner writes in.** Identifiers, Nix options and commands stay in English.

## Current state

- Hosts and VMs: nuc1 (`192.168.1.200`, host id 0) runs one k3s VM, `kube-0` (`.210`,
  server, embedded etcd), 9216 MB: derived from the host's RAM minus the reserves of what
  runs on it, floor 6912 MB (`modules/topology/_lib.nix`, checked by `nix flake check`).
  Never change a VM's size or limits without the owner's OK: the VM is the only node.
  A new host is data only: `docs/runbooks/add-host.md`.
- Topology: `modules/topology/topology.nix` holds hardware (`hosts`), the cluster, and where
  host services run (`services.<name>.on`); den (`modules/den/`, pinned v0.19.0) turns that
  into one configuration per host. Building blocks stay `flake.modules.nixos.*`.
- Cluster content (cert-manager, storage classes, OpenBao, Pocket-ID, Headscale, Lidarr,
  Navidrome, Syncthing, monitoring collectors, Grafana, apps) lives in the `homelab-cluster`
  repository, applied by Flux. Do not redeclare it here.
- Entry point: Cilium Gateways, public `192.168.1.240`, internal `.241` (Cilium LB-IPAM, L2
  announcements; no Traefik, no MetalLB), apps on `<app>.abe.lc` and `<app>.int.abe.lc`,
  wildcard Let's Encrypt certificate. Router: TCP 80/443 → `.240`, UDP 51820 and 41641 → nuc1.
- Secrets: sops-nix on the hosts (`secrets/<host>.yaml`, and `secrets/cluster.yaml` for what
  every host shares: the k3s token); in the cluster, OpenBao for apps and sops (Flux) for
  bootstrap only.
- VPN: Tailscale with Headscale in the cluster (`hs.abe.lc`, Pocket-ID login), nuc1 is the
  subnet router and an exit node for admins (`host/tailscale.nix`). WireGuard on nuc1
  (`10.250.0.0/24`) stays as break-glass. Dynamic DNS (ddclient) on nuc1. No impermanence on
  the host (D1 revised).
- Storage (D32): default class `local` (VM `local.img`, preallocated); `seaweedfs` for bulk
  files (data on host subvolume `@seaweed`); OpenBao on host subvolume `@openbao` (hourly
  btrbk snapshots). No NFS, no PostgreSQL on the host. Databases: CloudNativePG in the
  cluster (ADR 0006), backups in Garage on nuc1 (`host/garage.nix`), copied daily and
  encrypted to Cloudflare R2 (D31; stays under 8 GB, the unit fails above).
- Monitoring (D23): VictoriaMetrics, VictoriaLogs, vmalert, Alertmanager on nuc1 (alerts
  emailed from homelab@abe.lc to the owner's address, sops `alert-email`; heartbeat to
  Healthchecks.io); every host exports its own metrics (`host/telemetry.nix`); Grafana at
  `grafana.int.abe.lc`, in the cluster. Host rule: D22.
- Identity (D25): Pocket-ID at `auth.abe.lc`; the k3s API server accepts its tokens (topology
  `oidc`, `k3s/node.nix`). kubectl via kubelogin, Headlamp at `k8s.int.abe.lc` (VPN only); Hubble, Lidarr
  and Navidrome behind oauth2-proxy (Navidrome trusts its user header). Groups: `admins` (cluster-admin), `visitors`.
- Network (D27): Cilium (native routing, kube-proxy replacement, WireGuard, Hubble at
  `hubble.int.abe.lc`), installed by the base (`k3s/cilium.nix`). Flux: Flux Operator +
  FluxInstance (`k3s/flux.nix`).
- Updates (D26): Renovate PRs (weekly `flake.lock`), CI runs `nix flake check`, deploy by
  hand. k3s pinned to `k3s_1_36`.
- nuc1: new PSU since 2026-10-11, BIOS power limits. NIC offloads off (e1000e hang,
  2026-10-09).
- LAN guests (D34): `guests.<name>` in the topology, a systemd-nspawn container on `br0`
  with its own IP and firewall (`host/guest-containers.nix`). `music` (`.220`): Music
  Assistant, UI at `music.int.abe.lc` (8095 open to the Gateway, kube-0, only). `home`
  (`.221`): Home Assistant at `ha.int.abe.lc`, Pocket-ID login (`auth_oidc`, public client
  `home-assistant`). Music Assistant: login through Home Assistant (provider `hass`), so
  Pocket-ID only. `isolation = "vm"` is not wired yet.
- Memory: zram swap in the VM, kubelet LimitedSwap, eviction at 300 Mi. Check real free
  memory before adding an app (collapse of 2026-10-11).
- Addressing: `docs/facts.md`. Kubeconfigs (outside the repo): `~/.kube/configs/homelab-oidc.yaml`
  (Pocket-ID, daily use; public copy in homelab-cluster `docs/onboarding/kubeconfig.yaml`),
  `homelab-nix.yaml` (admin certificate, break-glass).
- Procedures: `docs/runbooks/` (bootstrap from an empty disk, add a host, lose a host), all
  written and none rehearsed yet.
- Open: CrowdSec's host bouncer stays until the v3 spike says otherwise; Mullvad for the
  download client is not ordered yet (D31 and open questions in `docs/03-…`).

Update this section when the state changes.

## Read before starting (in this order)

1. `docs/00-architecture.md` — principles, data model, layers.
2. `docs/03-decisions-and-open-questions.md` — decisions taken and open questions.
3. `docs/04-workloads.md` — boundary between this repository and `homelab-cluster`.
4. `docs/runbooks/`: bootstrap from an empty disk, add a host, lose a host.
5. The original phase 1 and phase 2 plans are in git history (removed 2026-10-11).

## Non-negotiable principles

1. **Everything that defines a VM is in code.** No VM image to keep or migrate. A microVM's
   root is a disposable tmpfs.
2. **Only stateful application data survives**, and nothing else.
3. **A single source of truth for the topology**: one data file
   (`modules/topology/topology.nix`). Moving a role to another host = changing one line in
   that file, nothing else.
4. **No conventional hypervisor** (no Proxmox/libvirt): `microvm.nix` only.
5. **No Terraform** for the cluster.
6. Downtime is acceptable when a role changes host. Zero downtime is not a goal.

## Code conventions

- **Dendritic pattern**: minimal `flake.nix`, `outputs = inputs: inputs.flake-parts.lib.mkFlake
  { inherit inputs; } (inputs.import-tree ./modules);`. Each file under `modules/` is a
  flake-parts module declaring `flake.modules.nixos.<name>` building blocks. Hosts compose
  these blocks; never hard-code lists of file paths.
- `flake.modules.*` requires importing `inputs.flake-parts.flakeModules.modules`.
- `import-tree` imports **every** `.nix` file under `modules/` as a flake-parts module. A file
  that is not one (e.g. `hardware-configuration.nix`) must live **outside `modules/`**
  (e.g. `hardware/nuc1.nix`) or under a path prefixed with `_` (ignored by import-tree).
- One file = one responsibility. Name building blocks after what they do.
- Style reference (to consult, not to copy blindly): https://github.com/Orysse/config

## Working rules

- **Never guess an option name.** Check with `nix eval`, `nixos-option`, the upstream source
  or the documentation before writing an option.
- `nix flake check` and a toplevel build of each host must pass before calling something done.
- **Ask for confirmation before any destructive or irreversible action**: wiping a disk
  (disko / nixos-anywhere), `rm -rf` outside the repository, `git push --force`.
- Only commit when asked to. No Claude co-author trailer in commit messages.
- **No secrets in the repository** (private keys, passwords, tokens) other than sops-encrypted
  files. *Public* SSH keys are fine.
- Deploy hosts with deploy-rs: it rolls back on its own if the host stops answering after
  activation (magic rollback, 30 s), so a network change cannot lock you out. Restarting
  a VM restarts its node: one at a time, and watch the cluster in between.
- When information is missing (network, hardware…), ask the owner rather than inventing it.

## Useful commands

```bash
nix flake check
nix build .#nixosConfigurations.nuc1.config.system.build.toplevel
nix eval .#nixosConfigurations.nuc1.config.microvm.vms --apply builtins.attrNames
nix run .#deploy-rs -- .#nuc1      # deploy one host (nix run .#deploy-rs -- . for all)
nixos-rebuild switch --rollback    # on the host, to go back by hand
```
