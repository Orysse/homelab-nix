# LAN guests: Music Assistant as a container on nuc1

Status: implemented 2026-11-11. Final choices: `reserves.base` 4352 → 3840 (kube-0 stays at
9216, the +1024 of §5 waits for the owner's OK); UI at music.int.abe.lc through the internal
Gateway, 8095 open to kube-0 (Envoy's source) only (and the VPN,
which routes .192/26), no SSO; the guest's journal is not shipped (shortcut in the module);
providers `airplay chromecast opensubsonic`.

## 1. Problem

The owner wants Roon-like playback at home: one library (Navidrome) played on a Chromecast
Audio, Google Home speakers and Apple devices (AirPlay), grouped and in sync. Music Assistant
does this. It does not fit the cluster:

- It finds players by mDNS (multicast) and must sit on the LAN itself.
- Its firewall needs are wide. With the `airplay` provider the NixOS module opens TCP 8097
  (stream), 5000 and 7000, and **UDP 32768–65535** (libraop's ephemeral ports).
- In kube-0 that means `hostNetwork` (Cilium policies no longer apply) and those ports open on
  the only node, which carries the API server and etcd. Rejected.

## 2. Which workloads this is for

The criterion: a workload belongs outside the cluster when it must be present on the LAN
(multicast, broadcast, random ports) or must outlive the cluster.

| Workload | Today | Verdict |
|---|---|---|
| Music Assistant | (new) | LAN guest |
| Navidrome, Lidarr, beets, Essentia | cluster | stay: HTTP behind the Gateway, data on SeaweedFS |
| qBittorrent, slskd | cluster | stay: everything goes out through gluetun |
| Syncthing | cluster, LB `.243` | stay: loses LAN broadcast discovery, direct address works |
| VPN, monitoring, Garage, CrowdSec bouncer | host | stay on the host (outlive the cluster, host netfilter) |

Only Music Assistant moves. Possible later members: Home Assistant, Snapcast, a DLNA server.
This is a narrow category, "LAN appliances", not a third general way to deploy.

## 3. Decision (to become D34)

**LAN appliances are guests of a host, not cluster apps.** A guest is described in the
topology like a VM, with its isolation as a field. The first guest is a NixOS container
(systemd-nspawn) with its own network namespace on `br0`.

Container rather than microVM:

- Memory is used on demand and capped (`MemoryMax`), instead of a fixed allocation the guest
  never gives back (no balloon, see `reserves.base` in `_lib.nix`).
- Much less code: the `vm` path needs den wiring for non-k3s guests and a split of
  `microvm-guest.nix`, which today is k3s-specific (OpenBao and SeaweedFS shares, zram).
- Weaker isolation: the host kernel is shared, and an escape lands on the hypervisor (all VMs,
  Garage backups). Mitigated by `privateUsers = "pick"` (container root is not host root) and
  the module's own hardening (§6). Accepted for a music player on the home LAN.

Moving a guest to a microVM later = changing `isolation` (principle 3), once the `vm` path exists.

Rejected: Music Assistant in kube-0 with `hostNetwork` (§1); as a plain service on the host
(wide firewall on the hypervisor itself); on the owner's laptop (not always on).

## 4. Data model

`cluster.vms` (`options.nix`) exists, is validated, and is unused (`vms = { }`). It becomes
`cluster.guests`, with one new field:

```nix
guests.music = {
  on = "nuc1";
  isolation = "container";        # "vm": not implemented yet, an assertion fails on it
  address = "192.168.1.220";
  mem = 512;                      # MB: reserved on the host, MemoryMax of the container
  module = {
    services.music-assistant = {
      enable = true;
      openFirewall = true;
      providers = [ "airplay" "chromecast" "subsonic" ];
    };
  };
};
```

The existing rules apply unchanged: address outside `.21x`, the DHCP range and the LB pool;
derived MAC unique; `vmMem` subtracts the guests' `mem` from the host's k3s VM.
To check during implementation: the provider names (`chromecast`, `subsonic`) against
`pkgs.music-assistant.providersBuiltins`.

## 5. Memory

Measured 2026-11-11 (nuc1, VictoriaMetrics):

| | |
|---|---|
| RAM | 15.7 GB |
| MemAvailable, minimum over 7 days | **4.8 GB** (window includes the 2026-11-07 deploy and its builds) |
| Host services now | ~550 MB (VictoriaMetrics 240, VictoriaLogs 110, Tailscale, Garage, Alertmanager, vmalert); virtiofsd ~1 GB |
| Host swap used, max over 7 days | 2.0 GB |
| kube-0 MemAvailable, minimum over 7 days | 1.45 GB |

The 3 GB headroom in `reserves.base` was never touched: the reserves are peaks (monitoring
reserves 1280 MB, uses ~400 MB today).

Proposal: `reserves.base` 4352 → 2816 MB. kube-0 goes 9216 → 10240 MB, the container takes 512.
Expected host minimum: 4.8 − 1.0 − 0.5 ≈ 3.3 GB, still above the intended 3 GB.
kube-0's new size applies only at its next manual restart (`restartIfChanged = false`).
**The VM size changes only with the owner's explicit OK** (CLAUDE.md).

Separate, not in this change: the host swaps 1.9 GB while 4.8 GB stay available. Likely cold
pages of the guest's RAM (memfd, swappable). Unverified; to look at on its own.

## 6. Security

- Own network namespace (`privateNetwork`, veth on `br0`), own IP `.220`, own firewall: the
  wide UDP range is open in the container only, not on the host nor on kube-0.
- `privateUsers = "pick"`: user namespace. To verify: `DynamicUser` (used by the module) works
  inside it.
- The module's hardening: `DynamicUser`, `CapabilityBoundingSet` = only `CAP_NET_BIND_SERVICE`
  (AirPlay 2 group sync on UDP 319/320), `Protect*`, `DevicePolicy = closed`,
  `RestrictAddressFamilies`. `MemoryDenyWriteExecute` is off upstream (pyopenssl, numba).
- UI on 8095: not opened by the module, reachable from inside the container only. To reach it
  from the LAN either open 8095 in the container firewall (Music Assistant has its own login)
  or put it behind the internal Gateway. **Open question**, see §9.
- Navidrome is reached at `https://navidrome.int.abe.lc` (public DNS → `.241`, the internal
  Gateway; `/rest/` is not behind SSO). Subsonic credentials are typed in the UI and stored in
  the container's state, not in the repo.

## 7. Implementation

1. `options.nix`: rename `vms` → `guests`, add `isolation` (enum `container` | `vm`).
2. `_lib.nix`: rename `vmsOn` → `guestsOn` and the validation messages; add an assertion that
   `isolation = "vm"` is not implemented yet. `reserves.base` per §5, if approved.
3. New block `host/guest-containers.nix`: for each guest of this host with
   `isolation = "container"`, a `containers.<name>`:
   `autoStart`, `privateNetwork`, `hostBridge = "br0"`, `localAddress = "<address>/24"`,
   `privateUsers = "pick"`, the guest's `module` plus networking (gateway, DNS from the
   topology), `systemd.services."container@<name>".serviceConfig.MemoryMax`, and journald
   upload to VictoriaLogs like `microvm-guest.nix`.
4. `den/hosts.nix`: include the block in `homelab-host` (it does nothing on a host without guests).
5. `topology.nix`: the `guests.music` entry.
6. State: `/var/lib/nixos-containers/music` on `@root`. No subvolume, no snapshot: lost, the
   Navidrome provider is set again in two minutes.
7. homelab-cluster: delete the uncommitted `apps/music/music-assistant.yaml` and its line in
   `apps/music/kustomization.yaml`.
8. Docs: D34 in `03-decisions-and-open-questions.md`, the boundary in `04-workloads.md`, the
   address in `facts.md`, "Current state" in `CLAUDE.md`.

## 8. Deploy and checks

1. `nix flake check`, toplevel build of nuc1.
2. `nix run .#deploy-rs -- .#nuc1` (magic rollback). The container starts on activation;
   kube-0 keeps running with its old size.
3. Checks: `machinectl status music`; from the LAN, `.220` answers on 8097; the Chromecast
   Audio, the Google Homes and the Apple devices appear on their own; a grouped play works;
   `systemctl show container@music -p MemoryCurrent` after a week.
4. If approved: restart kube-0 by hand (`systemctl restart microvm@kube-0`), watching the
   cluster. This is a full cluster outage of a few minutes.

Rollback: remove `guests.music` and redeploy; the container stops and its state stays on disk.

## 9. Open

- UI access: open 8095 on `.220` to the LAN, or route it through the internal Gateway (an
  HTTPRoute to an external address, plus SSO)? Leaning: open 8095 to the LAN and VPN only,
  Music Assistant's own login, no SSO (simplest).
- `reserves.base` 2816 (§5): owner's call.
- Does `DynamicUser` work under `privateUsers = "pick"`? Test at the first deploy.
- nixpkgs ships 2.10.6 (the container image is 2.10.9): fine, updates follow `flake.lock`.

## Out of scope

The `vm` isolation path; moving any other workload; the host swap question (§5).
