# Facts — 2026-10-07

| Topic | Value |
|---|---|
| Claude Code's machine | ThinkPad laptop, NixOS 26.11, x86_64 → local builds, no remote builder |
| Host | `nuc1`, NUC10i7FNH, 12 threads (VT-x OK), 16 GB RAM, UEFI |
| Disk | Kingston SNVS500G NVMe, 466 GB: `/dev/disk/by-id/nvme-KINGSTON_SNVS500G_50026B7685AD8136` |
| Network | Home router LAN `192.168.1.0/24`, gateway + DNS `192.168.1.1`. Router DHCP: `.10`–`.150`. A Google Wifi sits behind it (own NAT, `192.168.86.0/24`) |
| Static addressing (outside DHCP) | `.200`–`.209` hosts (`nuc1` = `.200`); `.210`–`.239` k3s nodes (`kube-N` = `.21N`); `.240`–`.254` LoadBalancers (MetalLB) |
| Port forwarding | TCP 80/443 → `192.168.1.240`; UDP 51820 → `192.168.1.200` |
| Domain | `abe.lc` (registrar OVH, DNS Cloudflare); `abe.lc` and `*.abe.lc` → public IP via ddclient |
| VPN | WireGuard, `10.250.0.0/24`, server `nuc1` (`10.250.0.1`) |
| mDNS | `nuc1.local`, `kube-N.local` resolved by systemd-resolved (host + VMs) |
| IPv6 | the router advertises an ISP prefix; disabled in the VMs (`IPv6AcceptRA = false`) so k3s stays on IPv4 |
| NUC NICs | `eno1` (built-in e1000e). Also: `enp57s0u1u4u2c2` (USB cdc_ncm, not bridged), iwlwifi Wi-Fi (not configured) |
| Timezone / keyboard | `Europe/Paris`, `us` |
| Access | root via the laptop's SSH key; console root password set by hand on the NUC (outside the repository) |
| Kubeconfig | `~/.kube/configs/homelab-nix.yaml` on the laptop (outside the repository) |
| nixpkgs | `nixos-unstable` (lock file versioned) |

## Troubleshooting: reaching the NUC without IPv4

Direct cable NUC ↔ laptop, then `ping -6 ff02::1%<iface>`: the NUC's `br0` answers at
`fe80::488:bdff:fe4c:a3db`. If NetworkManager disabled the interface for lack of DHCP:
`nmcli connection add save no type ethernet ifname <iface> con-name nuc-direct ipv4.method link-local ipv6.method link-local`.
For `nixos-rebuild` over link-local: `NIX_SSHOPTS="-o HostName=fe80::…%%<iface>" … --target-host root@nuc1`
(`%%`: ssh treats `%` as a token).
