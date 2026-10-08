# Clé age de Flux dérivée de la clé SSH d'hôte du server bootstrap (dans /persist) :
# rien à générer ni à sauvegarder. Nouvelle identité => sops updatekeys côté homelab-cluster.
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
        until k3s kubectl get namespace flux-system >/dev/null 2>&1; do sleep 5; done
        ssh-to-age -private-key -i /persist/ssh/ssh_host_ed25519_key \
          | k3s kubectl -n flux-system create secret generic sops-age \
              --from-file=age.agekey=/dev/stdin --dry-run=client -o yaml \
          | k3s kubectl apply -f -
      '';
    };
  };
}
