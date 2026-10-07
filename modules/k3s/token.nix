# Brique host : token k3s partagé, généré une fois sur le host (hors repo) et copié
# dans le /persist de chaque VM de ce host avant son démarrage.
# Si un nœud change de host, copier /var/lib/homelab/k3s-token sur le nouveau host.
# Cible : sops-nix (D10).
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.k3s-token = { config, lib, pkgs, ... }:
    let
      clusterLib = import ../cluster/_lib.nix { inherit lib; };
      nodes = lib.attrNames (clusterLib.nodesOn cluster config.networking.hostName);
      tokenPath = "/var/lib/homelab/k3s-token";
    in
    {
      systemd.services.homelab-k3s-token = {
        description = "Génère et distribue le token k3s aux microVMs";
        wantedBy = [ "microvms.target" ];
        before = map (n: "microvm@${n}.service") nodes;
        requiredBy = map (n: "microvm@${n}.service") nodes;
        after = [ "systemd-tmpfiles-setup.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          UMask = "0077";
        };
        path = [ pkgs.coreutils pkgs.openssl ];
        script = ''
          if [ ! -s ${tokenPath} ]; then
            mkdir -p "$(dirname ${tokenPath})"
            openssl rand -hex 32 > ${tokenPath}
          fi
          for n in ${lib.escapeShellArgs nodes}; do
            install -D -m 0600 ${tokenPath} /var/lib/microvms/$n/persist/k3s-token
          done
        '';
      };

      # Les images de volume ne doivent pas être en copy-on-write sur btrfs
      # (fragmentation). +C ne s'applique qu'aux fichiers créés ensuite.
      systemd.tmpfiles.settings."20-microvm-nocow" = lib.genAttrs
        (map (n: "/var/lib/microvms/${n}") nodes)
        (_: { h.argument = "+C"; });
    };
}
