# homelab-nix — contexte pour Claude Code

Homelab NixOS déclaratif : un cluster k3s tournant dans des microVMs (`microvm.nix`)
sur un ou plusieurs hosts physiques. Projet de showcase personnel, mais l'infra doit
être sensée et tenir une vraie stack. Le propriétaire prépare aussi un entretien chez
Datadog : Datadog sera déployé dans le cluster plus tard (phase 2+).

**Réponds en français.** Les identifiants, options Nix et commandes restent en anglais.

## Phase en cours

**Phase 2 — k3s.** Phase 1 terminée (G0–G6 validés le 2026-10-07). Le cluster k3s tourne :
`kube-1` server (etcd, `clusterInit`), `kube-2`/`kube-3` agents (`modules/k3s/`). PAS encore
de Longhorn, sops-nix ni Datadog. Pas d'impermanence sur le host (D1 révisée).
NUC sur le LAN de la Livebox, IP statiques hors DHCP : `nuc1` `.200`, `kube-N` `.21N` (`docs/facts.md`).
Voir `docs/04-workloads.md` (frontière socle / GitOps), `docs/03-decisions-and-open-questions.md` et `docs/facts.md`.
Contenu du cluster (MetalLB, Traefik, apps) : repo `homelab-cluster`, appliqué par Flux. Ne pas le redéclarer ici.
Point d'entrée : Traefik sur `192.168.1.240` (MetalLB), apps sur `<app>.192-168-1-240.sslip.io`.

Kubeconfig (hors repo) : `~/.kube/configs/homelab-nix.yaml` sur le laptop.
Quand une phase est terminée, mets à jour cette section.

## À lire avant de commencer (dans cet ordre)

1. `docs/00-architecture.md` — principes, modèle de données, couches.
2. `docs/01-phase1-provisioning.md` — la tâche : étapes, critères de réussite, pièges.
3. `docs/03-decisions-and-open-questions.md` — décisions prises et questions encore ouvertes.
4. `docs/02-phase2-k3s-preview.md` — uniquement pour garder la direction en tête, ne rien implémenter.

## Principes non négociables

1. **Tout ce qui définit une VM est dans le code.** Pas d'image de VM à conserver ni à
   migrer. Le root d'une microVM est un tmpfs jetable.
2. **Seules les données stateful des applications survivent**, et uniquement elles.
3. **Une seule source de vérité pour la topologie** : un fichier de données
   (`modules/topology/topology.nix`). Déplacer un rôle d'un host à l'autre = changer
   une ligne dans ce fichier, rien d'autre.
4. **Pas d'hyperviseur classique** (pas de Proxmox/libvirt) : `microvm.nix` uniquement.
5. **Pas de Terraform** pour le cluster.
6. Downtime acceptable lors d'un changement de host d'un rôle. Zéro-downtime n'est pas un objectif.

## Conventions de code

- **Dendritic pattern** : `flake.nix` minimal, `outputs = inputs: inputs.flake-parts.lib.mkFlake
  { inherit inputs; } (inputs.import-tree ./modules);`. Chaque fichier sous `modules/`
  est un module flake-parts qui déclare des briques `flake.modules.nixos.<nom>`.
  Les hosts composent ces briques ; jamais de liste de chemins de fichiers en dur.
- Pour que `flake.modules.*` existe il faut importer `inputs.flake-parts.flakeModules.modules`.
- `import-tree` importe **tous** les `.nix` sous `modules/` en tant que modules flake-parts.
  Un fichier qui n'en est pas un (ex. `hardware-configuration.nix`) doit vivre **hors de
  `modules/`** (ex. `hardware/nuc1.nix`) ou dans un chemin préfixé par `_` (ignoré par import-tree).
- Un fichier = une responsabilité. Nommer les briques par ce qu'elles font.
- Référence de style (à consulter, pas à copier aveuglément) : https://github.com/Orysse/config

## Règles de travail

- **Ne devine jamais un nom d'option.** Le brouillon initial de ce projet a été écrit sans
  être évalué et contenait des erreurs (voir « Pièges » dans la doc phase 1). Vérifie avec
  `nix eval`, `nixos-option`, le code source upstream ou la doc avant d'écrire une option.
- `nix flake check` et un build du toplevel de chaque host doivent passer avant de dire « terminé ».
- **Demande confirmation avant toute action destructive ou irréversible** : effacer un disque
  (disko / nixos-anywhere), `rm -rf` hors du repo, `git push --force`.
- Ne commit que quand on te le demande ; propose un commit à chaque « gate » franchi.
- **Aucun secret dans le repo** (clés privées, mots de passe, tokens). Les clés SSH *publiques* sont OK.
- Après un changement réseau sur un host distant, utilise `nixos-rebuild test` (revient au
  reboot) avant `switch`, pour ne pas te couper l'accès.
- Quand une information manque (réseau, matériel…), pose la question au propriétaire plutôt
  que d'inventer. La liste des informations nécessaires est dans la doc phase 1, étape 0.

## Commandes utiles

```bash
nix flake check
nix build .#nixosConfigurations.nuc1.config.system.build.toplevel
nix eval .#nixosConfigurations.nuc1.config.microvm.vms --apply builtins.attrNames
nixos-rebuild test   --flake .#nuc1 --target-host root@<ip> --build-host root@<ip>
nixos-rebuild switch --flake .#nuc1 --target-host root@<ip> --build-host root@<ip>
nixos-rebuild switch --rollback    # sur le host
```
