# Token generated on the host, outside the repository. When a node moves to another host,
# copy /var/lib/homelab/k3s-token there. Target: sops-nix (D10).
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
        description = "Generate the k3s token and distribute it to the microVMs";
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

      # Volume images without btrfs copy-on-write (fragmentation); +C only applies to
      # files created afterwards.
      systemd.tmpfiles.settings."20-microvm-nocow" = lib.genAttrs
        (map (n: "/var/lib/microvms/${n}") nodes)
        (_: { h.argument = "+C"; });
    };
}
