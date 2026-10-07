# Clé de déchiffrement sops de Flux, sans aucun secret à gérer à la main :
# la clé SSH d'hôte du server bootstrap (stable, dans /persist) est convertie en clé age
# et posée dans le Secret flux-system/sops-age, que Flux utilise pour déchiffrer les
# fichiers *.sops.yaml de homelab-cluster.
#
# Destinataires sops côté homelab-cluster (.sops.yaml) : cette clé + la clé perso de
# l'admin. Si le nœud perd son identité, l'admin rechiffre avec `sops updatekeys`.
{
  flake.modules.nixos.k3s-bootstrap = { config, pkgs, ... }: {
    systemd.services.flux-sops-age = {
      description = "Publie la clé age du nœud dans flux-system/sops-age";
      wantedBy = [ "multi-user.target" ];
      after = [ "k3s.service" ];
      requires = [ "k3s.service" ];
      path = [ pkgs.ssh-to-age config.services.k3s.package ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
        TimeoutStartSec = "15min";
      };
      script = ''
        # Le namespace est créé par le chart flux2 : on attend qu'il existe.
        until k3s kubectl get namespace flux-system >/dev/null 2>&1; do sleep 5; done
        ssh-to-age -private-key -i /persist/ssh/ssh_host_ed25519_key \
          | k3s kubectl -n flux-system create secret generic sops-age \
              --from-file=age.agekey=/dev/stdin --dry-run=client -o yaml \
          | k3s kubectl apply -f -
      '';
    };
  };
}
