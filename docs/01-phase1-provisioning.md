# Phase 1 — Provisioning du host et des microVMs

## Objectif

Un NUC10 (16 Go de RAM) sous NixOS qui, après **n'importe quel reboot**, relance seul 3 microVMs
joignables en SSH sur le LAN, entièrement dérivées du flake. Aucun k3s dans cette phase.

Hors périmètre : k3s, Longhorn, sops-nix, Datadog, cert-manager, ingress, backup NAS.

## Étape 0 — Poser les questions au propriétaire

Ne commence pas à écrire de code avant d'avoir ces réponses. Consigne-les dans `docs/facts.md`.

1. **Où tourne Claude Code ?** Sur un laptop (architecture et OS ? un Mac/ARM ne sait pas builder du `x86_64-linux` sans builder distant) ou directement sur le NUC ?
2. **Matériel du NUC** : modèle exact, RAM (16 Go ?), disques (NVMe seul ? un SATA en plus ?) avec leurs chemins `/dev/disk/by-id/…`, virtualisation (VT-x) activée dans le BIOS, boot UEFI.
3. **Le disque peut-il être entièrement effacé ?** Contient-il quelque chose à garder ? (Réponse explicite exigée avant toute installation.)
4. **Réseau** : le NUC est-il en Ethernet filaire ? Interface (nom) ? Subnet, passerelle, DNS. Quelle plage d'IP statiques hors DHCP pour le host (+ futurs hosts) et les VMs (3 maintenant, de la marge) ?
5. **Identité** : nom du host (défaut proposé : `nuc1`), noms des nœuds (défaut : `kube-1..3`), fuseau (`Europe/Paris` ?), disposition clavier/locale, clé(s) SSH **publique(s)** à autoriser.
6. **Canal nixpkgs** : défaut `nixos-unstable` (comme le repo de référence) sauf préférence contraire. Le `flake.lock` est versionné.
7. **Où est hébergé le repo** (privé ? public ?). Rappel : jamais de secret dedans.

Accès de secours : prévoir un écran + clavier branchables sur le NUC pendant les premiers tests
(une erreur de bridge sur une machine sans tête = machine injoignable).

## Étape 1 — Squelette du flake

Inputs attendus : `nixpkgs`, `flake-parts`, `import-tree`, `disko`, `microvm` (`preservation` retiré, voir D1)
(tous avec `inputs.nixpkgs.follows = "nixpkgs"` quand c'est possible).

Layout cible (à adapter, la logique compte plus que les noms) :

```
flake.nix                      # minimal : inputs + import-tree ./modules
hardware/nuc1.nix              # généré par nixos-generate-config, HORS de modules/
modules/
├─ parts.nix                   # systems = [ "x86_64-linux" ]; imports flakeModules.modules
├─ cluster/
│  ├─ options.nix              # déclare options.cluster.{network,hosts,nodes}
│  ├─ topology.nix             # LES DONNÉES (seule source de vérité)
│  └─ assertions.nix           # contrôles d'évaluation
├─ system/
│  ├─ base.nix                 # nix settings, fuseau, paquets de base
│  ├─ users-ssh.nix            # clés publiques, sshd, root sans mot de passe
│  ├─ boot.nix                 # systemd-boot, initrd systemd
│  ├─ disk-layout.nix          # disko : ESP + btrfs en sous-volumes
│  └─ network-bridge.nix       # br0 + attache des taps vm-*
├─ virtualization/
│  ├─ microvm-host.nix         # module host microvm.nix ; génère microvm.vms depuis cluster.nodes
│  └─ microvm-guest.nix        # base commune des invités
└─ hosts/
   ├─ nuc1.nix                 # disko (device), hardware, IP du host, composition + nixosConfigurations.nuc1
   └─ nuc2.nix                 # PLACEHOLDER évaluable uniquement, jamais déployé (voir gate G5)
docs/
```

## Étape 2 — Modèle de données et assertions

Implémenter `options.cluster` et `topology.nix` selon `docs/00-architecture.md` §3, avec les
assertions : noms uniques et ≤ 12 caractères, IP uniques et dans le subnet, `host` existant,
MAC dérivée unique. Écrire un petit test négatif (ex. deux nœuds avec la même IP doit faire échouer l'évaluation).

## Étape 3 — Host

- **Disque (disko)** : GPT, ESP 1 Go + une partition btrfs (`-L nixos`) avec les sous-volumes `@root` → `/`, `@nix` → `/nix`, `@log` → `/var/log`, `@microvms` → `/var/lib/microvms` (`compress=zstd,noatime`). Un seul pool plutôt que des partitions fixes : pas de taille à deviner. Swap : zram uniquement.
- **Pas d'impermanence** (D1 révisée).
- **Boot** : systemd-boot + EFI. **Pas de LUKS** en phase 1 (D2).
- **Accès** : root sans mot de passe, SSH par clé uniquement. **Aucun mot de passe en clair, aucune clé placeholder** dans le repo.
- **Réseau** : systemd-networkd ; bridge `br0` ; l'Ethernet physique est esclave de `br0` ; l'IP statique du host est sur `br0` ; les taps `vm-*` sont attachés à `br0`. S'inspirer de l'exemple officiel (✅ : `matchConfig.Name = [ "<nic>" "vm-*" ]` → `Bridge = "br0"`). Firewall : ne pas faire confiance en bloc à `br0` sans y avoir réfléchi — ouvrir ce qui est nécessaire (SSH).
- Ne **pas** fixer le nom de la NIC « de mémoire » : le lire dans `facts.md`.

## Étape 4 — microVMs

- Hôte : importer `inputs.microvm.nixosModules.host`. Hyperviseur **qemu** (support virtiofs, le plus compatible).
- Générer `microvm.vms.<nom>` pour chaque `node` dont `host == <ce host>`. Style « `config` » (entièrement déclaratif, dans la closure du host) : ✅ c'est la forme documentée ; la doc avertit que cela augmente temps de build et taille de closure du host (acceptable ici).
- Chaque invité (`microvm-guest.nix`) :
  - hostname = nom du nœud ; IP statique du nœud ; passerelle/DNS issus de `cluster.network`.
  - interface : `type = "tap"`, `id = "vm-<nom>"`, `mac` dérivée.
  - ✅ Network invité : `systemd.network.networks."20-lan".matchConfig.MACAddress = <mac dérivée>` avec `DHCP = "no"` (D13 : pas `Type = "ether"`).
  - partage `/nix/store` : `{ source = "/nix/store"; mountPoint = "/nix/.ro-store"; tag = "ro-store"; proto = "virtiofs"; }`.
  - **aucun `microvm.volumes`**, **pas** de `writableStoreOverlay`. Le root reste le tmpfs par défaut.
  - sshd actif, clés publiques autorisées (réutiliser la brique du host).
  - RAM/CPU depuis la topologie (2 Go / 2 vCPU chacun en phase 1, voir budget ci-dessous).
- **Identité stable** (voir D4) : un partage virtiofs par VM, `source = /var/lib/microvms/<nom>/persist` côté host, monté en `/persist` dans l'invité ; `services.openssh.hostKeys` pointe dedans. ✅ `machine-id` : déjà déterministe via `microvm.machineId` (défaut dérivé du hostname).
- ✅ `autostart` vaut `true` par défaut (on le fixe quand même explicitement) ; `restartIfChanged` vaut `true` par défaut en style `config`.
- ✅ RAM : **jamais exactement 2048 Mo**, QEMU se fige (warning microvm.nix#171) → 2000 Mo.

### Budget mémoire (16 Go)

| Poste | Go |
|---|---|
| host NixOS (+ page cache) | ~2 |
| 3 VMs × 2 Go (phase 1) | 6 |
| marge | ~8 |

En phase 2 k3s + Longhorn + agent Datadog poussera chaque VM vers 3–4 Go : 3 × 4 = 12 Go + host 2 Go = **serré**. Garder la RAM des nœuds dans la topologie pour l'ajuster sans toucher au reste. La RAM d'une VM qemu est réservée, pas partagée dynamiquement.

## Étape 5 — Installation sur le NUC (le propriétaire fait la partie physique)

**Actions humaines** :
1. Dans le BIOS : UEFI, VT-x activé, Ethernet branché.
2. Flasher l'ISO minimale NixOS sur une clé USB, démarrer le NUC dessus.
3. Faire en sorte que `ssh root@<ip-du-NUC>` fonctionne depuis la machine de Claude Code (typiquement : mettre la clé publique dans `/root/.ssh/authorized_keys` depuis la console de l'installeur). Noter l'IP.

**Actions de Claude Code** (après confirmation explicite que le disque peut être effacé) :
- Installer avec `nixos-anywhere` (`nix run github:nix-community/nixos-anywhere -- --flake .#nuc1 --target-host root@<ip>`), qui exécute disko puis installe. Générer la config matérielle avec l'option de génération de nixos-anywhere (`--generate-hardware-config nixos-generate-config ./hardware/nuc1.nix`) ⚠️ — vérifier les flags exacts avec `--help`.
- Si le build doit se faire sur le NUC (laptop non-x86_64) : option `--build-on remote` ⚠️.

## Gates de validation

Chaque gate doit être **démontrée** (sortie de commande collée dans le compte-rendu), pas supposée.

| Gate | Test | Attendu |
|---|---|---|
| **G0** | `nix flake check` ; build du toplevel de `nuc1` ; évaluation de `nuc2` ; test négatif (IP dupliquée) | tout passe sauf le test négatif qui échoue comme prévu |
| **G1** | sur le host : `findmnt -R /` ; reboot | sous-volumes montés comme prévu ; SSH par clé OK, mot de passe refusé |
| **G2** | sur le host : `systemctl list-units 'microvm@*'` ; depuis le laptop : `ssh` vers chaque IP ; dans une VM : `findmnt /` ; `find /var/lib/microvms -name '*.img'` | 3 VMs actives, joignables ; `/` = tmpfs ; **aucune image `.img`** |
| **G3** | `ping` entre les 3 VMs ; `ping` VM → LAN/Internet | OK |
| **G4** | `reboot` du host, sans aucune intervention | les 3 VMs rejoignables seules ; noter le délai ; **empreinte SSH de chaque VM inchangée** |
| **G5a** | `systemctl restart microvm@kube-2` | seule kube-2 redémarre ; même IP, même empreinte SSH, même machine-id |
| **G5b** | (évaluation seule) passer `kube-3.host = "nuc2"` dans la topologie | `nix eval` montre kube-3 absente de `nuc1` et présente dans `nuc2` ; aucun autre fichier modifié |
| **G6** | modifier la config d'une VM (ex. un paquet), `nixos-rebuild switch`, observer | la VM utilise la nouvelle closure (⚠️ voir D5 : sinon trouver le mécanisme de redémarrage correct) |
| G7 (bonus démo) | `nixos-rebuild switch --rollback` | retour à la génération précédente, VMs comprises |

## Pièges connus du brouillon initial (non testé, à ne PAS reprendre tel quel)

1. Reset btrfs au boot via `boot.initrd.postDeviceCommands` → sans objet (plus d'impermanence sur le host).
2. `inputs.microvm.flakeModule` importé dans `parts.nix` → je n'ai pas confirmé que cet export existe ; ne pas l'assumer.
3. Oublier `inputs.flake-parts.flakeModules.modules` → sans lui, `flake.modules.nixos.*` défini dans plusieurs fichiers ne fusionne pas.
4. Interface invité supposée `eth0` → faux/non garanti ; matcher la MAC dérivée (D13).
5. `hardware-configuration.nix` dans `modules/` → import-tree le traiterait comme un module flake-parts et casserait l'évaluation.
6. Volumes `.img` « persistent » et « rw-store » par VM → contraire au principe central ; supprimés.
7. Valeurs en dur (IP `10.0.10.x`, `eth0`, `/dev/sda`, clé SSH placeholder, mot de passe root) → tout vient de `facts.md` / de la topologie.
8. Token k3s en clair → sera traité en phase 2 avec sops-nix.

## Livrable de fin de phase 1

- Repo qui passe G0 → G6 (G7 optionnel), commits propres.
- `docs/facts.md` rempli.
- Un court `docs/phase1-report.md` : ce qui a marché, ce qui a dû être contourné, réponses finales aux points ⚠️, délais mesurés (G4).
- La section « Phase en cours » de `CLAUDE.md` mise à jour.
