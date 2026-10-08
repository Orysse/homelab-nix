# JSON rather than services.k3s.manifests.<x>.content: the nixpkgs YAML generator
# folds long strings in the middle of an escape sequence ("\\" -> "\ \").
{
  flake.modules.nixos.k3s-bootstrap = { config, lib, pkgs, ... }: {
    options.homelab.k3s.manifests = lib.mkOption {
      type = with lib.types; attrsOf (listOf attrs);
      default = { };
      description = "Kubernetes objects to apply, grouped by file (one file per app).";
    };

    config = {
      services.k3s.manifests = lib.mapAttrs (name: objects: {
        target = "${name}.json";
        source = pkgs.writeText "${name}.json"
          (builtins.toJSON { apiVersion = "v1"; kind = "List"; items = objects; });
      }) config.homelab.k3s.manifests;

      # The directory is on the persistent volume and tmpfiles never removes an undeclared
      # link: an old <x>.yaml would shadow the new <x>.json (same addon name).
      # k3s's own files are not links and are left untouched.
      systemd.services.k3s-prune-manifests =
        let
          cfg = config.services.k3s;
          declared = lib.mapAttrsToList (_: m: m.target)
            (lib.filterAttrs (_: m: m.enable) (cfg.autoDeployCharts // cfg.manifests));
        in
        {
          description = "Remove k3s manifests that are no longer declared";
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
              echo "removed undeclared manifest: $f"
              rm -f "$f"
            done
          '';
        };
    };
  };
}
