# Token généré sur le host, hors repo. Nœud déplacé sur un autre host : y copier
# /var/lib/homelab/k3s-token. Cible : sops-nix (D10).
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.k3s-token = { config, lib, pkgs, ... }:
    let
      clusterLib = import ../topology/_lib.nix { inherit lib; };
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

      # Images de volume sans copy-on-write btrfs (fragmentation) ; +C ne vaut que
      # pour les fichiers créés ensuite.
      systemd.tmpfiles.settings."20-microvm-nocow" = lib.genAttrs
        (map (n: "/var/lib/microvms/${n}") nodes)
        (_: { h.argument = "+C"; });
    };
}
