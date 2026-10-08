# Flux's own age key, generated once on the bootstrap server and kept in /persist.
# Not derived from the SSH host key: reading the sops-age Secret must not let anyone
# impersonate the node over SSH. The public key (flux-age.pub) is a recipient in
# homelab-cluster/.sops.yaml; if it changes, run `sops updatekeys` there.
{
  flake.modules.nixos.k3s-bootstrap = { config, pkgs, ... }: {
    systemd.services.flux-sops-age = {
      description = "Publish Flux's age key to flux-system/sops-age";
      wantedBy = [ "multi-user.target" ];
      after = [ "k3s.service" ];
      requires = [ "k3s.service" ];
      path = [ pkgs.age config.services.k3s.package ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
        TimeoutStartSec = "15min";
      };
      script = ''
        key=/persist/flux-age.key
        [ -s "$key" ] || age-keygen -o "$key"
        age-keygen -y "$key" > /persist/flux-age.pub
        until k3s kubectl get namespace flux-system >/dev/null 2>&1; do sleep 5; done
        k3s kubectl -n flux-system create secret generic sops-age \
          --from-file=age.agekey="$key" --dry-run=client -o yaml \
          | k3s kubectl apply -f -
      '';
    };
  };
}
