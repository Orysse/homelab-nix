# homelab-nix

Le **socle** du homelab : un NUC sous NixOS qui fait tourner trois microVMs
([microvm.nix](https://github.com/microvm-nix/microvm.nix)), qui forment un cluster k3s.
Tout est déclaré dans ce flake ; une VM n'a pas d'image disque, elle est reconstruite
depuis le code (root en tmpfs), seules les données k3s survivent sur un volume.

Ce repo s'arrête au cluster k3s qui démarre, avec Flux installé. **Ce qui tourne dedans**
(plateforme et apps) vit dans le repo `homelab-cluster`, appliqué par Flux (GitOps). Le socle
lui passe les paramètres réseau via la ConfigMap `cluster-vars` (voir `docs/04-workloads.md`).

## Couches

```
 LAN Livebox 192.168.1.0/24
   │
   ├── nuc1  192.168.1.200          NixOS · br0 · microvm.nix          modules/host, modules/vm
   │     ├── kube-1  .211  server   ┐
   │     ├── kube-2  .212  agent    ├─ k3s                             modules/k3s
   │     └── kube-3  .213  agent    ┘
   │
   └── 192.168.1.240                entrée HTTP(S) : MetalLB -> Traefik
```

| Couche | Outil | Où |
|---|---|---|
| Machines : host, VMs, k3s | Nix (`nixos-rebuild`) | ce repo |
| Contenu du cluster : plateforme, apps | Flux (git push) | `homelab-cluster` |
| Code des apps (ex. le site) | CI -> image | repo de chaque app |

## Où trouver quoi

```
flake.nix                  minimal : import-tree ./modules (dendritic pattern, flake-parts)
hardware/nuc1.nix          généré par nixos-generate-config (hors modules/ : pas un module flake-parts)
modules/
├─ topology/topology.nix   LA source de vérité : réseau, hosts, nœuds, point d'entrée
├─ topology/               son schéma (options.nix), ses helpers (_lib.nix), ses contrôles (assertions.nix)
├─ host/                   briques du host physique : disque, boot, ssh, bridge réseau
├─ vm/                     microVMs générées depuis la topologie (host + base invité)
├─ k3s/                    nœud k3s (rôle server/agent), token, installation de Flux
└─ machines/nuc1.nix       composition d'un host physique : quelles briques, quel disque, quelle NIC
docs/
├─ 00-architecture.md      principes
├─ 03-decisions-…md        décisions (Dn) et questions ouvertes
├─ 04-workloads.md         frontière socle / GitOps (Flux, cluster-vars)
└─ facts.md                matériel, réseau, adressage
```

Chaque fichier sous `modules/` est un module flake-parts qui déclare une brique
`flake.modules.nixos.<nom>` ; `machines/<host>.nix` les compose. Fichiers préfixés `_` :
helpers ignorés par import-tree.

## Commandes

```bash
nix flake check                                                         # évaluation + tests de topologie
nix build .#nixosConfigurations.nuc1.config.system.build.toplevel       # build complet (host + VMs)
nixos-rebuild switch --flake .#nuc1 --target-host root@192.168.1.200     # déployer
ssh root@192.168.1.211 k3s kubectl get nodes                            # état du cluster
```

Changer une IP, la RAM d'un nœud, déplacer un nœud sur un autre host : une ligne dans
`modules/topology/topology.nix`.
