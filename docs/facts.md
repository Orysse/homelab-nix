# Faits (étape 0) — 2026-10-07

| Sujet | Valeur |
|---|---|
| Machine de Claude Code | laptop ThinkPad, NixOS 26.11, x86_64 → build local, pas de builder distant |
| Host | `nuc1`, NUC10i7FNH, 12 threads (VT-x OK), 16 Go RAM, UEFI |
| Disque | NVMe Kingston SNVS500G 466 Go : `/dev/disk/by-id/nvme-KINGSTON_SNVS500G_50026B7685AD8136` |
| État avant install | NixOS 26.05 installé (ESP 1G + ext4 456G + swap 8,8G), user `admin`, sudo avec mot de passe, IP actuelle `192.168.1.2` sur `eno1` |
| Effacement du disque | **autorisé** (rien à garder) — reconfirmer juste avant nixos-anywhere |
| Réseau (final, 2026-10-07) | LAN de la Livebox, `192.168.1.0/24`, gw + DNS `192.168.1.1`. DHCP de la box : `.10`–`.150`. Un Google Wifi est derrière (son propre NAT `192.168.86.0/24`) |
| Adressage statique (hors DHCP) | `.200`–`.209` hosts (`nuc1` = `.200`) ; `.210`–`.239` nœuds k3s (`kube-N` = `.21N`) ; `.240`–`.254` réservé (LoadBalancer) |
| mDNS | `nuc1.local`, `kube-N.local` résolus par systemd-resolved (host + VMs) |
| IPv6 | la box annonce un préfixe opérateur ; désactivé dans les VMs (`IPv6AcceptRA = false`) pour que k3s reste en IPv4 |
| NIC du NUC | `eno1` (e1000e, intégrée). Aussi : `enp57s0u1u4u2c2` (USB cdc_ncm, non pontée), Wi-Fi iwlwifi (non configuré) |
| Fuseau / clavier | `Europe/Paris`, `us` |
| Accès | root par clé `~/.ssh/id_ed25519.pub` du laptop (abel@thinkpad) ; mot de passe root console défini à la main sur le NUC (hors repo) |
| Kubeconfig | `~/.kube/configs/homelab-nix.yaml` sur le laptop (hors repo) |
| nixpkgs | `nixos-unstable` (lock versionné) |
| Impermanence | **retirée** (D1 révisée) |

## Dépannage : retrouver le NUC sans IPv4

Câble direct NUC ↔ laptop, puis `ping -6 ff02::1%<iface>` : le `br0` du NUC répond en
`fe80::488:bdff:fe4c:a3db`. Si NetworkManager a désactivé l'interface faute de DHCP :
`nmcli connection add save no type ethernet ifname <iface> con-name nuc-direct ipv4.method link-local ipv6.method link-local`.
Pour `nixos-rebuild` via un lien local : `NIX_SSHOPTS="-o HostName=fe80::…%%<iface>" … --target-host root@nuc1`
(`%%` : ssh interprète `%` comme un jeton).
