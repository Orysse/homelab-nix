# homelab.k3s.manifests.<nom> = [ objets Kubernetes ]  ->  <nom>.json dans le dossier
# de manifests de k3s.
#
# Pourquoi pas directement services.k3s.manifests.<nom>.content : le module k3s les
# écrit en YAML, et son générateur replie les longues chaînes en coupant au milieu
# d'échappements (« \\ » devenait « \ \ » dans le contenu d'une ConfigMap). En JSON,
# rien n'est replié : ce qui est déclaré est exactement ce qui est appliqué.
{
  flake.modules.nixos.k3s-bootstrap = { config, lib, pkgs, ... }: {
    options.homelab.k3s.manifests = lib.mkOption {
      type = with lib.types; attrsOf (listOf attrs);
      default = { };
      description = "Objets Kubernetes à appliquer, groupés par fichier (un fichier par app).";
    };

    config = {
      services.k3s.manifests = lib.mapAttrs (name: objects: {
        target = "${name}.json";
        source = pkgs.writeText "${name}.json"
          (builtins.toJSON { apiVersion = "v1"; kind = "List"; items = objects; });
      }) config.homelab.k3s.manifests;

      # Le dossier de manifests est sur le volume persistant et NixOS n'y retire jamais
      # un lien qu'il ne déclare plus. Avant chaque démarrage de k3s, on supprime les
      # liens vers /nix/store non déclarés : le dossier reflète exactement le flake.
      # (Les fichiers propres à k3s - coredns.yaml, traefik.yaml… - ne sont pas des liens.)
      # Supprimer un manifest ne supprime pas ses ressources du cluster (comportement k3s).
      systemd.services.k3s-prune-manifests =
        let
          cfg = config.services.k3s;
          declared = lib.mapAttrsToList (_: m: m.target)
            (lib.filterAttrs (_: m: m.enable) (cfg.autoDeployCharts // cfg.manifests));
        in
        {
          description = "Retire les manifests k3s qui ne sont plus déclarés";
          wantedBy = [ "k3s.service" ];
          before = [ "k3s.service" ];
          after = [ "systemd-tmpfiles-setup.service" "systemd-tmpfiles-resetup.service" ];
          unitConfig.RequiresMountsFor = [ "/var/lib/rancher" ];
          serviceConfig.Type = "oneshot";
          script = ''
            dir=/var/lib/rancher/k3s/server/manifests
            [ -d "$dir" ] || exit 0
            for f in "$dir"/*; do
              [ -L "$f" ] || continue
              case "$(readlink "$f")" in /nix/store/*) ;; *) continue ;; esac
              case " ${toString declared} " in *" $(basename "$f") "*) continue ;; esac
              echo "manifest non déclaré, retiré : $f"
              rm -f "$f"
            done
          '';
        };
    };
  };
}
