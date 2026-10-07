# Décisions et questions ouvertes

Format : décision, raison, alternative écartée. « Ouvert » = à trancher avec le propriétaire.

## Décisions prises

**D1 (révisée le 2026-10-07) — Pas d'impermanence sur le host.**
Décision du propriétaire : preservation et root tmpfs retirés pour simplifier. Le host a un disque btrfs classique en sous-volumes (`@root` → `/`, `@nix`, `@log` → `/var/log`, `@microvms` → `/var/lib/microvms`) : on peut snapshoter/restaurer `@root` sans toucher au store, aux logs ni à l'état des VMs. Les **VMs** gardent leur root tmpfs (défaut microvm.nix) : le principe central est inchangé.

**D2 — Pas de LUKS en phase 1.**
Raison : un disque chiffré par passphrase empêche le redémarrage non assisté du host, alors que « reboot du host → tout revient seul » est un critère central. Alternative pour plus tard : déverrouillage TPM2 ou déverrouillage distant dans l'initrd.

**D3 — VMs directement sur le LAN (bridge), IP statiques.**
Raison : c'est le modèle documenté upstream et il permet à des VMs sur des hosts différents de se voir sans routage. Contrainte : host en Ethernet filaire. Alternative écartée : bridge privé + NAT par host (plus simple en solo mais casse la connectivité inter-hosts).

**D4 — Identité des VMs : petit partage virtiofs par VM (phase 1).**
Une VM doit garder les mêmes clés SSH d'hôte entre redémarrages, sinon avertissements `known_hosts` à chaque boot. On partage `/var/lib/microvms/<nom>/persist` du host vers `/persist` de l'invité (✅ dossier source créé par les tmpfiles du module host microvm.nix). C'est du *volume*, pas une image de VM.
Limite connue : si le nœud change de host, ce dossier doit suivre (ou on accepte de régénérer). Cible : clé d'hôte fournie comme secret (sops-nix) → VM réellement sans état.
✅ virtiofsd tourne en root côté host (service `microvm-virtiofsd@`, sans `User=`) avec `--posix-acl --xattr` par défaut : pas de problème d'uid attendu, à confirmer en G2.
✅ `machine-id` : `microvm.machineId` vaut par défaut un UUID dérivé du hostname et écrit `/etc/machine-id`. Rien à faire.

**D5 — VMs déclarées en style `config` (dans la closure du host).**
Raison : s'intègre naturellement au dendritic pattern et au `nixos-rebuild` du host. ✅ La doc dit que le répertoire d'état `/var/lib/microvms/<nom>` n'est créé qu'une fois.
(a) ✅ `restartIfChanged` vaut `true` par défaut en style `config` ; à démontrer en G6. (b) sans objet : `/var/lib/microvms` est un sous-volume btrfs persistant.

**D6 — Hyperviseur qemu.**
Raison : supporte virtiofs et 9p, le plus compatible. (✅ firecracker n'a ni 9p ni virtiofs ; cloud-hypervisor pas de 9p.)

**D7 — Pas d'overlay de store inscriptible.**
Raison : les VMs ne buildent pas ; l'overlay exige un volume (✅) donc une image — contraire au principe central.
Le seul volume par VM est le volume de *données* k3s (D9).

**D8 — Premier déploiement avec nixos-anywhere** (disko + install en une commande), ensuite `nixos-rebuild --target-host`.
Alternative : installation manuelle depuis l'ISO. Outil de déploiement multi-hosts (colmena, deploy-rs…) à reconsidérer quand il y aura un 2e host.

**D9 (2026-10-07) — État k3s sur un volume de données par VM.**
`microvm.volumes` : `/var/lib/microvms/<vm>/k3s-data.img` (ext4, fichier creux, `dataDisk` Mio dans la topologie, défaut 20 Gio, attribut btrfs `+C`) monté sur `/var/lib/rancher` ; `/etc/rancher` est un lien vers `/var/lib/rancher/etc`. Le root reste un tmpfs.
Raison : un état éphémère casse la ré-adhésion des nœuds (mot de passe de nœud rejeté) et met les images en RAM ; virtiofs ne convient pas (overlayfs de containerd). etcd est donc persistant.

**D10 (provisoire) — Token k3s : fichier hors repo.** Le service host `homelab-k3s-token` génère `/var/lib/homelab/k3s-token` une fois et le copie dans `/persist` de chaque VM avant son démarrage. Cible : sops-nix.

**D11 (2026-10-07) — RAM : kube-1 4000 Mo, agents 3000 Mo** (10 Go réservés sur 16). À revoir avec Longhorn + Datadog.

**D13 — Réseau invité matché par MAC, interfaces CNI non gérées.** `Type = "ether"` matchait aussi les veth des pods : networkd leur mettait l'IP du nœud et cassait le réseau des pods. `20-lan` matche la MAC dérivée ; `veth*`, `cni0`, `flannel*` sont `Unmanaged`.

## Questions ouvertes

**D10 bis — sops-nix** : clé age dérivée de la clé SSH d'hôte ? À mettre en place avant d'ajouter d'autres secrets.

**D12 — Où vit le repo et comment les mises à jour d'inputs sont gérées** (Renovate/CI auto-hébergée plus tard ?).
