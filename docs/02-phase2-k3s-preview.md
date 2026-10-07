# Phase 2 — aperçu k3s (NE RIEN IMPLÉMENTER pour l'instant)

Ce document sert uniquement à ce que les choix de la phase 1 ne ferment pas de portes.
Tout est à re-vérifier le moment venu.

## Direction

- k3s sur les microVMs : `kube-1` en server, `kube-2`/`kube-3` en agents (le `role` de la topologie sélectionne le module). Les agents rejoignent via `https://<ip kube-1>:6443`.
- À terme plusieurs control-planes en HA (etcd, nombre **impair** de servers) répartis sur plusieurs hosts. « Déplacer le control-plane » = faire naître un nouveau server ailleurs, le laisser se synchroniser, retirer l'ancien proprement (snapshot etcd avant) — jamais migrer une VM.
- Manifests : k3s applique automatiquement ceux de `/var/lib/rancher/k3s/server/manifests/` ; ils peuvent être générés depuis Nix. `kubenix` reste une option de confort, pas une nécessité ⚠️ (vérifier aussi ce que `services.k3s` de nixpkgs expose nativement).

## Points qui dépendent déjà de la phase 1

- **Secrets** : le token k3s ne doit jamais être en clair → sops-nix (ou équivalent) à introduire en tout début de phase 2. L'identité SSH des VMs (D4) pourra alors migrer vers des secrets au lieu d'un partage persistant.
- **Longhorn sur NixOS** : friction connue ⚠️ (Longhorn attend des binaires et chemins FHS — iscsiadm, nsenter… — absents de NixOS ; il faudra `services.openiscsi` et probablement des contournements de PATH). À rechercher avant de s'engager.
- **Stockage par nœud** : un volume de données par VM pour `/var/lib/longhorn` (seul cas légitime d'image par VM). La taille totale ×3 répliques doit tenir sur le NVMe.
- **Backup** : cible = NAS Synology (NFS ou S3 selon le modèle). Intervalle raisonnable, pas de sollicitation continue. Rappel : réplication ≠ backup, surtout avec un seul host physique.
- **etcd** : persistant (donc sur un volume) ou reconstruit depuis les manifests déclarés ? Question ouverte (voir D9).
- **RAM** : budget serré avec Longhorn + agent Datadog (voir doc phase 1).
- **Datadog** : DaemonSet dans k3s, agent aussi sur les hosts NixOS, scrape des métriques Longhorn, monitoring de l'API server/etcd/scheduler ; toute la config (checks, tags) déclarée dans le flake, pas dans l'UI.
- Ingress : Traefik fourni par k3s, à ne pas désactiver sans raison ; cert-manager si exposition HTTPS.
