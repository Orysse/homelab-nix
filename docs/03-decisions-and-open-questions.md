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

**D10 (provisional; superseded by D33) — k3s token: file outside the repository.** The `homelab-k3s-token` host service generates `/var/lib/homelab/k3s-token` once and copies it into each VM's `/persist` before it starts. Target: sops-nix.

**D11 (2026-10-07; superseded by D29) — RAM: kube-1 4000 MB, agents 3000 MB** (10 GB reserved out of 16).

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

**D21 (2026-10-09; superseded by D32) — All persistent data on the storage host (NFS), VMs disposable.**
nuc1 exports the top-level btrfs subvolume `@data` (`/srv/data`) over NFSv4.1+ to the three nodes only (TCP 2049, firewall per node IP, `no_root_squash` for the CSI controller); the cluster uses csi-driver-nfs with the default StorageClass `nfs`, one directory per volume `<namespace>_<pvc>` (the driver archives the first path component on delete, so no nesting). btrbk snapshots `@data` hourly into the top-level subvolume `@snapshots` (48 h, 14 d, 8 w). k3s `local-storage` is disabled and etcd snapshots go to `/persist` (virtiofs, on the host). Both subvolumes were created once on the live disk; disko creates them on a reinstall.
Reason: a VM must be destroyable without losing data; data stays readable and restorable on the host. Rejected: local-path (state inside the VM disk), Longhorn (replicated state inside the VMs, RAM), virtiofs + local-path (pods pinned to a node, single host only). Next: offsite copy (restic from the snapshots).

**D22 (2026-10-09) — What runs on the hosts, what runs in the cluster.**
On the hosts (NixOS): what carries the cluster or is needed to repair it — hypervisor, VPN, storage (D21), DDNS, bootstrap secrets (sops-nix), and the monitoring backends and alerting (D23). In the cluster (Flux): everything else, including stateful services (Pocket-ID, OpenBao, apps), whose data lives on NFS. Host services are placed by role in the topology (`vpn.host`, `storage.host`, `monitoring.host`), so a second host only takes topology lines. Hosts will be deployed with deploy-rs (automatic rollback if a host stops answering) before a second host is added. HA is not a goal (principle 6): nothing lost, everything rebuilt.

**D24 (2026-10-09; superseded by D28 and D32) — Databases: PostgreSQL on the database host, credentials owned by OpenBao.**
Apps never keep SQLite on NFS (no reliable file locking; Pocket-ID refuses it with a warning). PostgreSQL 18 runs on the database host (`postgres.nix`, role `database.host`) on the top-level subvolume `@db` (local disk, not under the NFS export, snapshotted by btrbk). One database and one user per app, named after its Kubernetes namespace (`database.databases` in the topology); only the nodes connect, scram-sha-256. OpenBao's database engine (`database/postgres`) owns the app users' passwords (static roles, set by OpenBao in PostgreSQL); a namespace reads only its own credentials (templated policy) through an External Secrets `VaultDynamicSecret` generator. The `openbao` PostgreSQL role (ADMIN on the app roles) has its password in sops, on both sides. Rotation yearly for now (apps read the password at start). Rejected: CloudNativePG (state inside the VMs or on NFS).

**D23 (2026-10-09) — Monitoring: VictoriaMetrics, VictoriaLogs, vmalert, Alertmanager on the monitoring host; Grafana and collectors in the cluster.**
Datadog took about 1.8 GB in the VMs (a third of their used memory) for a use case it does not fit. Backends on nuc1 (`monitoring.nix`, `alerting.nix`): metrics and logs stay home and keep their history when the cluster is down; vmalert evaluates the rules (`_alert-rules.nix`) and Alertmanager emails them through the `homelab@abe.lc` mailbox (OVH, SPF/DKIM/DMARC pass), so alerts still fire with the cluster down. The nodes ship their journals too (systemd-journal-upload: k3s, kubelet, API audit). In the cluster: Grafana Alloy (metrics + logs, node-local), kube-state-metrics (with Flux object state), node-exporter, and Grafana for dashboards only (provisioned from git, database in PostgreSQL, D24). Standard split (alerts in the metrics backend, Grafana for display). Collectors ~0.5 GB in the VMs. Heartbeat: the always-firing Watchdog alert is sent every minute to a Healthchecks.io ping URL (sops `heartbeat-url`), which emails the owner when the pings stop: monitoring host down, internet down, or alerting pipeline broken. Traces: later (Tempo) if an instrumented app appears.

**D25 (2026-10-09) — Identity: Pocket-ID, OIDC everywhere, groups decide.**
Pocket-ID (in the cluster, `auth.abe.lc`, state in PostgreSQL) is the only login: passkeys, admin UI for users, groups and OIDC clients, email invitations and one-time codes through `homelab@abe.lc`. The k3s API server trusts it through a structured `AuthenticationConfiguration` (`k3s/node.nix`): issuer and accepted client IDs (`kubernetes` for kubectl with kubelogin, public + PKCE; `headlamp` for the web console) come from the topology (`oidc`), users and groups are prefixed `oidc:`, anonymous requests are refused. Rights are RBAC on Pocket-ID groups (homelab-cluster: `admins` is cluster-admin). Grafana and OpenBao log in through the same provider. Break-glass: the k3s admin client certificate. API audit (`k3s/node.nix`): what people do (OIDC users and the admin certificate: every change, and who read secrets or config maps; Metadata level, never content), not controllers or service accounts; written to the k3s journal and shipped to VictoriaLogs. Query in Grafana: `_SYSTEMD_UNIT:k3s.service "audit.k8s.io" | unpack_json | fields _time, user.username, verb, objectRef.namespace, objectRef.resource, objectRef.name, responseStatus.code`. Rejected: Authelia (file backend, hash exchange by hand), Keycloak (too heavy for the homelab).

**D26 (2026-10-09) — Updates: Renovate pull requests, checked by CI, deployed by hand.**
Both repositories are on GitHub. homelab-cluster: Renovate PRs for charts and images, applied by Flux on merge. homelab-nix: Renovate updates `flake.lock` weekly (lock file maintenance, Monday morning) and the GitHub Actions; CI (`.github/workflows/check.yml`) runs `nix flake check`, which builds nuc1 with its microVMs. After merging, the owner deploys with deploy-rs (magic rollback). nixpkgs follows nixos-unstable, so pinned on purpose: the Kubernetes minor version (`pkgs.k3s_1_36`, upgraded one minor at a time) and PostgreSQL's major version (`postgresql_18`, a major upgrade needs a data migration).

**D27 (2026-10-10) — Cluster network: Cilium instead of flannel and kube-proxy.**
Cilium 1.20 (`k3s/cilium.nix`), installed by the base as a k3s *bootstrap* HelmChart (host network, before the nodes are Ready): Flux cannot install the network it needs to run. Native routing (the nodes share a LAN, IPAM from the k3s pod CIDRs), kube-proxy replacement (services in eBPF), BPF masquerading, WireGuard between nodes (as flannel did), Hubble (UI at `hubble.int.abe.lc`, metrics scraped by Alloy, Cilium dashboards in Grafana). k3s runs with `--flannel-backend=none --disable-network-policy --disable-kube-proxy`; CNI files go to the standard paths (`/etc/cni/net.d`, `/opt/cni/bin`, on the VMs' tmpfs root, rewritten by Cilium at start): without flannel, k3s points containerd there. Pod-to-node traffic is no longer NATed, so the nodes accept the pod CIDR on the kubelet and Hubble ports. Why: eBPF observability and L3–L7 network policies, a widely used standard. Cost: ~300 MB per node. Migration: etcd snapshot, deploy, restart the VMs (pods recreated); about 10 minutes of downtime.

**D28 (2026-10-29) — Cluster v3: one data plane, operators for state, OTLP.**
The cluster was rethought as a whole, same purpose, every means open (homelab-cluster spec `docs/superpowers/specs/2026-10-29-cluster-v3-design.md`, one ADR per decision in `docs/adr/`). Here, in the base: k3s keeps only upstream Kubernetes, Traefik and servicelb off (ADR 0001); Cilium also does LoadBalancer IPs (L2 announcements) and Gateway API, the CRDs being a k3s manifest (`k3s/gateway-api.nix`, ADR 0002); Flux comes from the Flux Operator and one FluxInstance (`k3s/flux.nix`); each VM gets a block volume for local PersistentVolumes (`localDisk`), so PostgreSQL moves into the cluster on CloudNativePG (ADR 0006) with its backups in Garage on nuc1 (`host/garage.nix`, `backup.host`); the electricity estimate is recording rules over RAPL, unit-tested with vmalert-tool (`host/_power-rules.nix`, `host/power.nix`). In the cluster: OpenBao configured by self-initialization only (ADR 0005), Pocket-ID and OIDC clients from an operator (ADR 0004), CrowdSec bans enforced by Cilium through our own bouncer (ADR 0003), the OpenTelemetry Collector instead of Alloy (ADR 0007). Removed: MetalLB, Traefik, Tetragon, vault-config-operator, Umami, OpenCost, Headplane.

**D29 (2026-11-05) — One k3s VM per host, its memory derived.**
The cluster runs on one VM, `kube-0` (`.210`, server), on nuc1, instead of three: the memory the other two held was mostly page cache and duplicated agents. A VM's memory is the host's RAM minus the reserves of what runs on that host (`reserves` in `topology/_lib.nix`), rounded down to 64 MB, with a floor of 6912 MB (`nix flake check`). nuc1: 16384 MB, so 9216 MB, approved by the owner. Measured before and after in homelab-cluster `docs/measurements.md`. Rejected: keeping three VMs on one host (three kernels and node agents for no isolation gain).

**D30 (2026-11-05) — Hosts are hardware, workloads say where they run (den).**
`hosts` holds hardware only; `services.<name>.on` places host services; den (`github:denful/den`, pinned v0.19.0, `modules/den/`) turns both into per-host configurations, the k3s VM being a guest of its host. The building blocks stay plain `flake.modules.nixos.*`. A host is added with data only (`docs/runbooks/add-host.md`). Cost: den pulls about 25 transitive repositories at evaluation, pinned by hash in den's own source, not in `flake.lock`; the microVM integration is copied from den's template, not from its library (`den/policies.nix`). Rejected: the same model written in plain flake-parts (more code of our own), clan.

**D31 (2026-11-05) — Backups: Garage on nuc1, a daily encrypted copy to Cloudflare R2.**
Garage (S3, `host/garage.nix`) holds the CNPG base backups and WAL. `garage-offsite` copies the bucket daily to a Cloudflare R2 bucket (free tier: 10 GB stored), encrypted client-side by rclone `crypt` (password and salt in sops and in the password manager); the unit fails from 8 GB, which raises `OffsiteCopyFailed`. It is a mirror (`rclone sync`), not a versioned archive: R2 has no versioning. The same unit copies the latest hourly btrbk snapshot of `` (D32). Restore tested 2026-11-05: a CNPG cluster recovered from the R2 copy. A NAS is not available yet; when it is, it becomes a second target. Rejected: restic to the NAS (none yet).

**D32 (2026-11-05) — Storage v3: `local` by default, SeaweedFS for bulk files; no NFS, no host PostgreSQL.**
The default StorageClass is `local` (local-path on the VM's `local.img`, preallocated at start). Bulk shared files (the music library) use StorageClass `seaweedfs`: SeaweedFS with its filer metadata in CNPG, volume data on the host subvolume `` (virtiofs into the VM, nocow, not snapshotted); validated by a spike on six criteria (hardlink and rename, a 10 000-file scan, Syncthing, memory, reinstall keeps the files, a 4 GB torrent). OpenBao's data moved from NFS to the host subvolume `` (hourly btrbk snapshots, crash-consistent, plus the daily copy to R2): a database restored from a btrfs snapshot recovers like after a crash. CloudNativePG replaced the host PostgreSQL (ADR 0006); the NFS server, `csi-driver-nfs`, `` and `` are gone from the configuration (the subvolumes stay on disk, unmounted, until the owner deletes them). Supersedes D21 and D24. Open: with several hosts, the volume servers need a DaemonSet of our own (the chart's is a StatefulSet).

**D33 (2026-11-05) — One k3s token for every host, in sops.**
`secrets/cluster.yaml` (key `k3s-token`) is encrypted to every host and installed into each VM's persist before it starts. One token, not one per role: on a LAN with one operator, a compromised host already controls its own VM; a separate agent token would add a secret and a role-dependent rule for little gain. Supersedes D10.

**D34 (2026-11-11) — LAN appliances are guests of a host, not cluster apps.**
A workload that must sit on the LAN itself (multicast discovery, random ports) is a `guests.<name>` entry of the topology: a systemd-nspawn container on `br0` with its own address and firewall (`host/guest-containers.nix`), `privateUsers = "pick"`, capped at its `mem` (also reserved from the host). Guests: Music Assistant (`music`, `.220`; mDNS, UDP 32768–65535 for AirPlay) and Home Assistant (`home`, `.221`; login through Pocket-ID with the `auth_oidc` component). Music Assistant speaks no OIDC: its login goes through Home Assistant (provider `hass`), so one identity, Pocket-ID; if Home Assistant is down, its local accounts still work. (An oauth2-proxy in front plus its own login was tried first: two logins.) UIs only through the internal Gateway. Their RAM comes out of `reserves.base` (2816): kube-0 stays at 9216; more room means dropping an app, not the headroom. Rejected: `hostNetwork` in kube-0 (those ports on the only node, Cilium policies bypassed); a plain host service (wide firewall on the hypervisor); a microVM (fixed RAM never given back, and den has no wiring for non-k3s guests yet: `isolation = "vm"` fails a check until it does). Accepted risk: a container shares the host kernel. Spec: `docs/specs/2026-11-11-lan-guests.md`.

**Hardware note (2026-10-09).** nuc1 runs on a 65 W power supply (90 W expected): CPU bursts cut it during switches, which also left the Nix store with registered but missing paths. CPU limits were capped at PL1 = PL2 = 25 W until a new supply arrived on 2026-10-11; since then the BIOS defaults apply (PL1 30 W, PL2 64 W, tau 28 s). After any power cut during a deploy: `nix-store --verify --check-contents` on the host before redeploying. The I219 NIC (e1000e) hung for good under load the same day ("Detected Hardware Unit Hang", nuc1 offline for 20 minutes, kernel otherwise fine): TSO/GSO are now disabled at boot (`lan-nic-offload` in `machines/nuc1.nix`). If it happens again: `ethtool -k eno1`, and consider a USB NIC. etcd snapshots: k3s silently skipped them for a day because `/persist/etcd-snapshots` did not exist (seen in the node journals); now created by tmpfiles.

## Open questions

**Security audit (2026-10-08)** — done: YubiKey SSH key for root (laptop file key kept as fallback), VPN clients limited to the homelab, flannel over WireGuard, node-only etcd/kubelet/memberlist, k3s secrets encryption, dedicated Flux age key, HTTP security headers, CAA (Let's Encrypt), Renovate (D26). Open: GitHub 2FA and branch protection on both repositories (owner), Cloudflare Universal SSL to disable (it adds its own CAs to the CAA set).

**Off-site backups.** Done for the CNPG backups and OpenBao (D31, Cloudflare R2). Not covered: the music library (re-fetched with Lidarr, and kept on the DAP), metrics and logs. A NAS would add a second target.

**CrowdSec outcome (v3 spike).** Whether Cilium can enforce CrowdSec's bans with an upstream, maintained integration (then the host bouncer, `host/crowdsec-bouncer.nix`, is removed), or the host bouncer stays. Undecided: it stays until the spike says otherwise.

**VPN for the download client.** Mullvad (WireGuard), to be ordered by the owner: qBittorrent is deployed switched off until its configuration exists (homelab-cluster `apps/music/qbittorrent.yaml`).

**Friends on the cluster (2026-10-09).** A restricted tenant (namespace, quotas, network isolation) was built and tested for a friend, then dropped by the owner: trusted friends are admins (group `admins`). Their VPN peer still has an access list (API and internal gateway only, not the host or the LAN). Their API actions are traced by the Kubernetes audit log (D25).
