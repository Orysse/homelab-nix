# En JSON plutôt que via services.k3s.manifests.<x>.content : le générateur YAML de
# nixpkgs replie les longues chaînes au milieu d'un échappement (« \\ » -> « \ \ »).
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

      # Le dossier est sur le volume persistant et tmpfiles ne retire jamais un lien non
      # déclaré : un ancien <x>.yaml masquerait le nouveau <x>.json (même nom d'addon).
      # Les fichiers de k3s lui-même ne sont pas des liens et restent intacts.
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
