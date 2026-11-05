# One k3s token for the whole cluster, copied into each k3s VM's persist before it starts.
# k3s encrypts its bootstrap data with the server's token: the value must never change
# (`k3s token rotate` otherwise), and every host needs the same one.
# With secrets/cluster.yaml (key `k3s-token`, encrypted to every host, D10) it comes from
# sops. Until that file exists, the host generates it in /var/lib/homelab/k3s-token as
# before.
# shortcut: the generated fallback, drop it once secrets/cluster.yaml is committed.
{ config, ... }:
let
  inherit (config) cluster;
  clusterSecret = ../../secrets/cluster.yaml;
  fromSops = builtins.pathExists clusterSecret;
in
{
  flake.modules.nixos.k3s-token = { config, lib, pkgs, ... }:
    let
      clusterLib = import ../topology/_lib.nix { inherit lib; };
      vm = clusterLib.k3sVmOf cluster config.networking.hostName;
      nodes = lib.optional (vm != null) vm.name;
      tokenPath = if fromSops then config.sops.secrets.k3s-token.path else "/var/lib/homelab/k3s-token";
    in
    {
      sops.secrets = lib.optionalAttrs fromSops { k3s-token.sopsFile = clusterSecret; };

      systemd.services.homelab-k3s-token = {
        description = "Install the k3s token into the microVMs";
        wantedBy = [ "microvms.target" ];
        before = map (n: "microvm@${n}.service") nodes;
        requiredBy = map (n: "microvm@${n}.service") nodes;
        after = [ "systemd-tmpfiles-setup.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          UMask = "0077";
        };
        path = [ pkgs.coreutils ] ++ lib.optional (!fromSops) pkgs.openssl;
        script = ''
          ${lib.optionalString (!fromSops) ''
            if [ ! -s ${tokenPath} ]; then
              mkdir -p "$(dirname ${tokenPath})"
              openssl rand -hex 32 > ${tokenPath}
            fi
          ''}
          for n in ${lib.escapeShellArgs nodes}; do
            install -D -m 0600 ${tokenPath} /var/lib/microvms/$n/persist/k3s-token
          done
        '';
      };

      # local.img is sparse: a full host disk would make writes fail under the databases
      # that live on it. Allocate it once the VM has created it (nocow, so the blocks stay
      # ours). The data disk (re-pullable images) stays sparse.
      systemd.services.homelab-vm-prealloc = lib.mkIf (vm != null) {
        description = "Allocate the local volume of ${vm.name}";
        wantedBy = [ "microvms.target" ];
        after = [ "microvm@${vm.name}.service" ];
        path = [ pkgs.coreutils ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        script = ''
          img=/var/lib/microvms/${vm.name}/local.img
          for _ in $(seq 120); do [ -e "$img" ] && break; sleep 1; done
          fallocate -l ${toString vm.localDisk}M "$img"
        '';
      };

      # Volume images without btrfs copy-on-write (fragmentation); +C only applies to
      # files created afterwards.
      systemd.tmpfiles.settings."20-microvm-nocow" = lib.genAttrs
        (map (n: "/var/lib/microvms/${n}") nodes)
        (_: { h.argument = "+C"; });
    };
}
