# Contenu du cluster : frontière socle / GitOps

Ce repo (le socle) s'arrête à un cluster k3s qui tourne et à **Flux installé**. Tout ce qui
tourne dans le cluster — MetalLB, config de Traefik, apps — vit dans le repo
`homelab-cluster` et est appliqué par Flux à chaque `git push`.

Raison (D14) : les manifests déclarés en Nix font partie de la config de la VM `kube-1` ;
chaque modification d'app reconstruisait et **redémarrait le control-plane**. Nix gère les
machines, Flux gère le contenu.

## Ce que le socle déclare (modules/k3s/)

| Fichier | Rôle |
|---|---|
| `flux.nix` | chart Helm `flux2` figé (version + hash), `GitRepository` + `Kustomization` vers `cluster.gitops`, ConfigMap `cluster-vars` |
| `manifests.nix` | `homelab.k3s.manifests.<nom>` -> `<nom>.json` dans le dossier de manifests de k3s ; retire au démarrage les manifests qui ne sont plus déclarés |
| `node.nix` | rôle server/agent, volume de données, `servicelb` désactivé (MetalLB le remplace) |

Le tout n'est appliqué que par le server bootstrap (`kube-1`).

## Le pont : cluster-vars

Le réseau reste défini une seule fois, dans `modules/topology/topology.nix`. Le socle en
publie les valeurs utiles au cluster dans `flux-system/cluster-vars`, que Flux substitue :

| Topologie | Variable dans homelab-cluster |
|---|---|
| `cluster.ingress.domain` | `${DOMAIN}` |
| `cluster.ingress.address` | `${INGRESS_ADDRESS}` |
| `cluster.ingress.pool` | `${INGRESS_POOL}` |

Changer le domaine (ex. passer à `abelc.eu`) = une ligne dans la topologie + `nixos-rebuild`.

## Pourquoi JSON (manifests.nix)

`services.k3s.manifests.<x>.content` est écrit en YAML par le module nixpkgs, dont le
générateur replie les longues chaînes en coupant au milieu d'échappements (`\\` -> `\ \`,
vu sur le contenu d'une ConfigMap). On écrit nos manifests en JSON : rien n'est replié.

## Ajouter une app

Dans `homelab-cluster` (voir son README), pas ici.
