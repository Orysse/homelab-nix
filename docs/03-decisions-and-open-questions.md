# Decisions and open questions

Format: decision, reason, rejected alternative. "Open" = to be settled with the owner.

## Decisions

**D1 (revised 2026-10-07) — No impermanence on the host.**
Owner's decision: preservation and tmpfs root removed for simplicity. The host has a regular btrfs disk with subvolumes (`@root` → `/`, `@nix`, `@log` → `/var/log`, `@microvms` → `/var/lib/microvms`): `@root` can be snapshotted/restored without touching the store, the logs or the VMs' state. The **VMs** keep their tmpfs root (microvm.nix default): the core principle is unchanged.

**D2 — No LUKS for now.**
Reason: a passphrase-encrypted disk prevents unattended host reboots, while "host reboot → everything comes back on its own" is a core criterion. Alternative for later: TPM2 unlock or remote unlock in the initrd.

**D3 — VMs directly on the LAN (bridge), static IPs.**
Reason: the upstream-documented model, and it lets VMs on different hosts reach each other without routing. Constraint: the host must be on wired Ethernet. Rejected alternative: private bridge + NAT per host (simpler alone, but breaks inter-host connectivity).

**D4 — VM identity: a small virtiofs share per VM.**
A VM must keep the same SSH host keys across restarts, otherwise `known_hosts` warnings at every boot. `/var/lib/microvms/<name>/persist` on the host is shared to `/persist` in the guest (✅ source directory created by the microvm.nix host module's tmpfiles). It is a *volume*, not a VM image.
Known limit: if the node changes host, this directory must follow (or keys are regenerated).
✅ virtiofsd runs as root on the host (`microvm-virtiofsd@` service, no `User=`) with `--posix-acl --xattr` by default: no uid issues.
✅ `machine-id`: `microvm.machineId` defaults to a UUID derived from the hostname and writes `/etc/machine-id`.

**D5 — VMs declared in `config` style (inside the host closure).**
Reason: fits the dendritic pattern and the host's `nixos-rebuild` naturally. ✅ `restartIfChanged` defaults to `true` in `config` style (verified at G6).

**D6 — qemu hypervisor.**
Reason: supports virtiofs and 9p, the most compatible. (✅ firecracker has neither 9p nor virtiofs; cloud-hypervisor has no 9p.)

**D7 — No writable store overlay.**
Reason: VMs do not build; the overlay requires a volume (✅), hence an image — contrary to the core principle. The only per-VM volume is the k3s *data* volume (D9).

**D8 — First deployment with nixos-anywhere** (disko + install in one command), then `nixos-rebuild --target-host`.
Since 2026-10-09: **deploy-rs** (`modules/deploy.nix`), one node per host of the topology, magic rollback. Chosen over colmena: flake-native, and the rollback protects remote network changes.

**D9 (2026-10-07) — k3s state on a data volume per VM.**
`microvm.volumes`: `/var/lib/microvms/<vm>/k3s-data.img` (ext4, sparse file, `dataDisk` MiB in the topology, 20 GiB default, btrfs `+C` attribute) mounted on `/var/lib/rancher`; `/etc/rancher` is a link to `/var/lib/rancher/etc`. The root stays a tmpfs.
Reason: ephemeral state breaks node re-joining (node password rejected) and keeps images in RAM; virtiofs does not work for it (containerd overlayfs). etcd is therefore persistent.

**D10 (provisional) — k3s token: file outside the repository.** The `homelab-k3s-token` host service generates `/var/lib/homelab/k3s-token` once and copies it into each VM's `/persist` before it starts. Target: sops-nix.

**D11 (2026-10-07) — RAM: kube-1 4000 MB, agents 3000 MB** (10 GB reserved out of 16).

**D13 — Guest network matched by MAC, CNI interfaces unmanaged.** `Type = "ether"` also matched the pods' veths: networkd gave them the node's IP and broke pod networking. `20-lan` matches the derived MAC; `veth*`, `cni0`, `flannel*` are `Unmanaged`.

**D14 (2026-10-07) — Base in Nix, cluster content in GitOps (Flux).**
This repository stops at k3s + Flux; MetalLB, Traefik, cert-manager, the monitoring collectors, Grafana and the apps live in `homelab-cluster` (public, GitHub), applied by Flux. Reason: declared in Nix, the manifests were part of the `kube-1` VM configuration — every app change restarted the control plane. The network stays defined once (Nix topology) and reaches the cluster through the `cluster-vars` ConfigMap.
Rejected alternatives: Argo CD (heavier on RAM), apps in the same repository (mixing tools).

**D15 (2026-10-08) — Domain `abe.lc`: registrar OVH, DNS at Cloudflare.**
Cloudflare's API is natively supported by cert-manager (no webhook) and by ddclient, with zone-scoped tokens. Keeping the registrar separate means the DNS provider can be changed without transferring the domain. DNSSEC enabled (DS published through OVH).

**D16 (2026-10-08) — Exposure through router port forwarding.**
TCP 80/443 → `192.168.1.240` (MetalLB IP of Traefik), UDP 51820 → nuc1 (VPN). Records are DNS-only (no Cloudflare proxy); the public IP is kept up to date by ddclient on nuc1. Rejected for now: Cloudflare Tunnel, VPS relay.

**D17 (2026-10-08) — HTTPS: cert-manager, DNS-01 via Cloudflare, wildcard certificate.**
A single `*.abe.lc` certificate served by default by Traefik (TLSStore `default`); HTTP redirects to HTTPS. DNS-01 does not depend on the cluster being reachable.

**D18 (2026-10-08) — Secrets: sops + age everywhere.**
Recipients: the owner's software age key (itself encrypted for their YubiKey in `nix-secrets`) and YubiKey, plus the consumer: the host's SSH host key converted to age (sops-nix on nuc1), and a dedicated age key generated on kube-1 for Flux (not derived from its SSH host key, so reading the Secret does not allow impersonating the node).

**D19 (2026-10-08, replaced by D23 on 2026-10-09) — Datadog on the US5 site.** Agent on nuc1 (Nix) and in the cluster (Datadog Operator), same cluster tag. Workaround in place for a nixpkgs-unstable build failure of the Python integrations.

**D20 (2026-10-08) — Admin VPN: WireGuard on nuc1**, `10.250.0.0/24` (`10.100.0.0/24` is used by a school tunnel). Clients only route `192.168.1.192/26`, so remote LANs in `192.168.1.0/24` are not shadowed.

**D21 (2026-10-09) — All persistent data on the storage host (NFS), VMs disposable.**
nuc1 exports the top-level btrfs subvolume `@data` (`/srv/data`) over NFSv4.1+ to the three nodes only (TCP 2049, firewall per node IP, `no_root_squash` for the CSI controller); the cluster uses csi-driver-nfs with the default StorageClass `nfs`, one directory per volume `<namespace>_<pvc>` (the driver archives the first path component on delete, so no nesting). btrbk snapshots `@data` hourly into the top-level subvolume `@snapshots` (48 h, 14 d, 8 w). k3s `local-storage` is disabled and etcd snapshots go to `/persist` (virtiofs, on the host). Both subvolumes were created once on the live disk; disko creates them on a reinstall.
Reason: a VM must be destroyable without losing data; data stays readable and restorable on the host. Rejected: local-path (state inside the VM disk), Longhorn (replicated state inside the VMs, RAM), virtiofs + local-path (pods pinned to a node, single host only). Next: offsite copy (restic from the snapshots).

**D22 (2026-10-09) — What runs on the hosts, what runs in the cluster.**
On the hosts (NixOS): what carries the cluster or is needed to repair it — hypervisor, VPN, storage (D21), DDNS, bootstrap secrets (sops-nix), and the monitoring backends and alerting (D23). In the cluster (Flux): everything else, including stateful services (Pocket-ID, OpenBao, apps), whose data lives on NFS. Host services are placed by role in the topology (`vpn.host`, `storage.host`, `monitoring.host`), so a second host only takes topology lines. Hosts will be deployed with deploy-rs (automatic rollback if a host stops answering) before a second host is added. HA is not a goal (principle 6): nothing lost, everything rebuilt.

**D24 (2026-10-09) — Databases: PostgreSQL on the database host, credentials owned by OpenBao.**
Apps never keep SQLite on NFS (no reliable file locking; Pocket-ID refuses it with a warning). PostgreSQL 18 runs on the database host (`postgres.nix`, role `database.host`) on the top-level subvolume `@db` (local disk, not under the NFS export, snapshotted by btrbk). One database and one user per app, named after its Kubernetes namespace (`database.databases` in the topology); only the nodes connect, scram-sha-256. OpenBao's database engine (`database/postgres`) owns the app users' passwords (static roles, set by OpenBao in PostgreSQL); a namespace reads only its own credentials (templated policy) through an External Secrets `VaultDynamicSecret` generator. The `openbao` PostgreSQL role (ADMIN on the app roles) has its password in sops, on both sides. Rotation yearly for now (apps read the password at start). Rejected: CloudNativePG (state inside the VMs or on NFS).

**D23 (2026-10-09) — Monitoring: VictoriaMetrics, VictoriaLogs, vmalert, Alertmanager on the monitoring host; Grafana and collectors in the cluster.**
Datadog took about 1.8 GB in the VMs (a third of their used memory) for a use case it does not fit. Backends on nuc1 (`monitoring.nix`, `alerting.nix`): metrics and logs stay home and keep their history when the cluster is down; vmalert evaluates the rules (`_alert-rules.nix`) and Alertmanager emails them through the `homelab@abe.lc` mailbox (OVH, SPF/DKIM/DMARC pass), so alerts still fire with the cluster down. In the cluster: Grafana Alloy (metrics + logs, node-local), kube-state-metrics (with Flux object state), node-exporter, and Grafana for dashboards only (provisioned from git, database in PostgreSQL, D24). Standard split (alerts in the metrics backend, Grafana for display). Collectors ~0.5 GB in the VMs. Heartbeat: the always-firing Watchdog alert is sent every minute to a Healthchecks.io ping URL (sops `heartbeat-url`), which emails the owner when the pings stop: monitoring host down, internet down, or alerting pipeline broken. Traces: later (Tempo) if an instrumented app appears.

**D25 (2026-10-09) — Identity: Pocket-ID, OIDC everywhere, groups decide.**
Pocket-ID (in the cluster, `auth.abe.lc`, state in PostgreSQL) is the only login: passkeys, admin UI for users, groups and OIDC clients, email invitations and one-time codes through `homelab@abe.lc`. The k3s API server trusts it through a structured `AuthenticationConfiguration` (`k3s/node.nix`): issuer and accepted client IDs (`kubernetes` for kubectl with kubelogin, public + PKCE; `headlamp` for the web console) come from the topology (`oidc`), users and groups are prefixed `oidc:`, anonymous requests are refused. Rights are RBAC on Pocket-ID groups (homelab-cluster: `admins` is cluster-admin; tenants get namespaced roles). Grafana and OpenBao log in through the same provider. Break-glass: the k3s admin client certificate. Rejected: Authelia (file backend, hash exchange by hand), Keycloak (too heavy for the homelab).

**D26 (2026-10-09) — Updates: Renovate pull requests, checked by CI, deployed by hand.**
Both repositories are on GitHub. homelab-cluster: Renovate PRs for charts and images, applied by Flux on merge. homelab-nix: Renovate updates `flake.lock` weekly (lock file maintenance, Monday morning) and the GitHub Actions; CI (`.github/workflows/check.yml`) runs `nix flake check`, which builds nuc1 with its microVMs. After merging, the owner deploys with deploy-rs (magic rollback). nixpkgs follows nixos-unstable, so pinned on purpose: the Kubernetes minor version (`pkgs.k3s_1_36`, upgraded one minor at a time) and PostgreSQL's major version (`postgresql_18`, a major upgrade needs a data migration).

**Hardware note (2026-10-09).** nuc1 runs on a 65 W power supply (90 W expected): CPU bursts cut it during switches, which also left the Nix store with registered but missing paths. CPU limits PL1 = PL2 = 25 W (`machines/nuc1.nix`). After any power cut during a deploy: `nix-store --verify --check-contents` on the host before redeploying.

## Open questions

**Security audit (2026-10-08)** — done: YubiKey SSH key for root (laptop file key kept as fallback), VPN clients limited to the homelab, flannel over WireGuard, node-only etcd/kubelet/memberlist, k3s secrets encryption, dedicated Flux age key, HTTP security headers, CAA (Let's Encrypt), Renovate (D26). Open: GitHub 2FA and branch protection on both repositories (owner), Cloudflare Universal SSL to disable (it adds its own CAs to the CAA set).

**Off-site backups.** Today only btrbk snapshots, on the same disk as the data: a dead disk loses everything. Planned: restic of `@data` and `@db` to a NAS at the owner's father's (to be repaired first).

**Tenants.** A namespace with admin rights for a friend (Pocket-ID group, Headlamp, VPN peer limited to the API, quotas). Guardrails drafted on branch `tenant-lenny`; on hold.
