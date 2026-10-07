# Architecture

Légende : ✅ = vérifié dans la doc/le code upstream le 2026-10-07 · ⚠️ = non vérifié, à confirmer avant de s'y fier.

## 1. Vue d'ensemble

```
LAN (ex. 192.168.x.0/24)
 │
 ├── nuc1  (host physique, NixOS, br0 = IP du host)
 │     ├── microVM kube-1   ─┐
 │     ├── microVM kube-2    ├─ taps vm-* rattachés à br0, IP statiques sur le LAN
 │     └── microVM kube-3   ─┘
 │
 └── nuc2…  (futurs hosts : même modèle, mêmes modules, juste une entrée de plus dans la topologie)
```

Trois couches à garder séparées :

| Couche | Rôle | Persistance |
|---|---|---|
| **host** | NixOS physique, hyperviseur (`microvm.nix`), bridge | disque btrfs classique en sous-volumes, **pas d'impermanence** (D1) |
| **VM** | un « nœud » : config à froid + éventuellement un petit volume d'identité | root tmpfs jetable, aucune image |
| **pod** (phase 2) | workloads k3s | données stateful dans des PVC (Longhorn) |

## 2. Principe central

> Une VM est un objet constitué d'une **configuration à froid** (le code Nix) donnée à
> l'instant 0, plus des **volumes montés** pour ce qui est réellement stateful.
> Tuer la VM A et démarrer la VM B avec la même définition doit juste « redémarrer les services ».

Conséquences :

- Pas d'image disque de VM à sauvegarder ou migrer. Les VMs vivent sur leur host et peuvent être effacées au redémarrage.
- ✅ Dans microvm.nix, le root d'un invité est **déjà un tmpfs** par défaut (`fsType = "tmpfs"`, `size=50%`) : il n'y a rien à configurer pour l'impermanence *dans* la VM.
- ✅ Le `/nix/store` du host est partagé en lecture seule dans l'invité (share virtiofs) ; cela évite d'avoir une image squashfs volumineuse.
- Une **overlay de store inscriptible** n'est pas nécessaire : les VMs ne font pas de `nix build`, elles sont reconstruites par le host. ✅ Elle exigerait de toute façon un *volume* (les shares 9p/virtiofs ne fonctionnent pas avec overlayfs). **On n'en met pas.**
- Le seul état qu'on tolère pour une VM en phase 1 est une toute petite **identité** (clés SSH d'hôte). Voir décision D4.

## 3. Modèle de données : la topologie est une donnée

C'est la pièce centrale pour « si je change le code, le control-plane est là et plus là où il était ».

Un fichier `modules/cluster/topology.nix` contient la seule description de qui tourne où :

```nix
# schéma indicatif — à affiner à l'implémentation
cluster = {
  network = { subnet = "192.168.X.0/24"; gateway = "192.168.X.1"; dns = [ "…" ]; };
  hosts = {
    nuc1 = { address = "192.168.X.10"; };
    # nuc2 = { address = "192.168.X.11"; };   # futur
  };
  nodes = {
    kube-1 = { host = "nuc1"; address = "192.168.X.21"; role = "server"; mem = 2048; vcpu = 2; };
    kube-2 = { host = "nuc1"; address = "192.168.X.22"; role = "agent";  mem = 2048; vcpu = 2; };
    kube-3 = { host = "nuc1"; address = "192.168.X.23"; role = "agent";  mem = 2048; vcpu = 2; };
  };
};
```

Règles :

- Chaque module host **génère ses `microvm.vms`** à partir des `nodes` dont `host == <ce host>`. Aucune VM n'est décrite à la main dans un fichier host.
- `node.host` est un scalaire : un nœud ne peut donc **pas** être sur deux hosts en même temps, par construction.
- MAC et nom de tap sont **dérivés** du nom du nœud (déterministes). ✅ Contraintes upstream : MAC de la forme `02:00:00:…` ; id de tap `vm-*` (c'est le motif que matche le bridge). Un nom d'interface Linux fait ≤ 15 caractères → **nom de nœud ≤ 12 caractères** (assertion).
- Assertions d'évaluation : noms uniques, IP uniques, IP dans le subnet, MAC uniques, `host` référence un host existant, longueur du nom.
- Le `role` n'a aucun effet en phase 1 (métadonnée). En phase 2 il sélectionne les modules k3s.

## 4. Réseau

- ✅ Modèle upstream : un bridge `br0` géré par systemd-networkd ; l'interface Ethernet physique **et** les taps `vm-*` sont rattachés à `br0` ; l'IP du host est portée par `br0`.
- Les VMs sont donc **directement sur le LAN** avec des IP statiques (hors de la plage DHCP du routeur). C'est ce qui permettra à des VMs sur des hosts différents de se voir sans routage supplémentaire.
- Contrainte : l'interface du host doit être **filaire** (un bridge sur du Wi-Fi ne fonctionne pas).
- ✅ Côté invité, matcher l'interface par sa **MAC dérivée** (`matchConfig.MACAddress`), pas par `Type = "ether"` qui matche aussi les veth des pods k3s (D13), ni par un nom comme `eth0`.
- Phase 2 : flannel/vxlan (UDP 8472) de k3s fournit le réseau des pods par-dessus.

## 5. Stockage

- **Host** : pas d'impermanence. NVMe unique : ESP 1 Go + btrfs en sous-volumes `@root`, `@nix`, `@log`, `@microvms` (voir `modules/system/disk-layout.nix`). Pas de LUKS en phase 1 (voir D2).
- **VM** : aucun volume en phase 1, hormis le petit partage d'identité (D4).
- **Phase 2** : les données applicatives vont dans Longhorn. Attention, Longhorn réplique *entre nœuds* mais, avec un seul host physique, les trois répliques sont sur le même disque : **la réplication n'est pas un backup**. La cible de backup prévue est le NAS Synology du propriétaire, à intervalle raisonnable (« ne pas le tabasser »).
- Longhorn exigera un vrai disque par nœud pour `/var/lib/longhorn`. Ce sera le seul cas légitime de volume (`.img`) par VM : c'est un volume de *données*, pas une image de VM.

## 6. Ce qui est explicitement écarté

- Terraform pour le cluster ; Proxmox/libvirt/KubeVirt.
- Zéro-downtime lors du déplacement d'un rôle.
- « Même disque / même réseau visibles de n'importe où » dans le sens fort : seuls la connectivité IP entre VMs et le stockage distribué des données applicatives sont requis.
