# Garage: S3 storage for the cluster's backups (CloudNativePG base backups and WAL), on
# the backup host (topology backup.host) until the NAS takes over. Single node,
# replication factor 1: the copy that matters is off the cluster's disks, not
# replicated. Data in its own btrfs subvolume, snapshotted read-only by btrbk
# (storage.nix): a deletion through S3 keys cannot reach the snapshots.
# Only the nodes may reach the S3 API; RPC and the admin API (metrics) stay on localhost.
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.garage = { config, lib, pkgs, ... }:
    let
      clusterLib = import ../topology/_lib.nix { inherit lib; };
      nodeIPs = clusterLib.vmIPs cluster;
      garage = "${config.services.garage.package}/bin/garage";
    in
    {
      sops.secrets.garage-rpc-secret = { };
      sops.templates."garage.env".content =
        "GARAGE_RPC_SECRET=${config.sops.placeholder.garage-rpc-secret}";

      services.garage = {
        enable = true;
        package = pkgs.garage_2;
        environmentFile = config.sops.templates."garage.env".path;
        settings = {
          replication_factor = 1;
          metadata_dir = "/srv/backups/meta";
          data_dir = "/srv/backups/data";
          # A consistent copy of the metadata database, for the btrbk snapshots to hold.
          metadata_auto_snapshot_interval = "6h";
          rpc_bind_addr = "127.0.0.1:3901";
          rpc_public_addr = "127.0.0.1:3901";
          s3_api = {
            api_bind_addr = "[::]:3900";
            s3_region = "garage";
          };
          # No admin token: only /metrics and /health answer.
          admin.api_bind_addr = "127.0.0.1:3903";
        };
      };

      # A fixed user rather than DynamicUser: the data lives outside /var/lib.
      users.users.garage = { isSystemUser = true; group = "garage"; };
      users.groups.garage = { };
      systemd.services.garage.serviceConfig = {
        DynamicUser = false;
        User = "garage";
        Group = "garage";
      };
      systemd.tmpfiles.settings.garage."/srv/backups".v = {
        user = "garage";
        group = "garage";
        mode = "0750";
      };
      # The units bind-mount these paths (ReadWritePaths): they must exist before Garage starts.
      systemd.tmpfiles.settings.garage."/srv/backups/meta".d = { user = "garage"; group = "garage"; mode = "0750"; };
      systemd.tmpfiles.settings.garage."/srv/backups/data".d = { user = "garage"; group = "garage"; mode = "0750"; };
      # Nested in @root (created by tmpfiles above, not by disko); snapshotted with @data by
      # storage.nix's btrbk instance, which mounts the top level at /mnt/btrfs.
      services.btrbk.instances.data.settings.volume."/mnt/btrfs".subvolume."@root/srv/backups" = { };

      # Layout, bucket and key, created once. The key's secret is read by hand
      # (garage key info cnpg --show-secret) and stored in OpenBao kv/apps/postgres/s3.
      systemd.services.garage-setup = {
        description = "Garage single-node layout, bucket and key for CloudNativePG";
        after = [ "garage.service" ];
        requires = [ "garage.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          TimeoutStartSec = "2min";   # a switch waits for this unit: never forever
          EnvironmentFile = config.sops.templates."garage.env".path;
        };
        script = ''
          until ${garage} status >/dev/null 2>&1; do sleep 1; done
          if ${garage} status | grep -q "NO ROLE ASSIGNED"; then
            ${garage} layout assign -z ${config.networking.hostName} -c 50G "$(${garage} node id -q | cut -d@ -f1)"
            ${garage} layout apply --version 1
          fi
          ${garage} bucket info cnpg >/dev/null 2>&1 || ${garage} bucket create cnpg
          ${garage} key info cnpg >/dev/null 2>&1 || ${garage} key create cnpg
          ${garage} bucket allow --read --write cnpg --key cnpg
        '';
      };

      networking.firewall.extraCommands = lib.concatMapStrings
        (ip: "iptables -A nixos-fw -p tcp -s ${ip} --dport 3900 -j nixos-fw-accept\n")
        nodeIPs;
    };
}
