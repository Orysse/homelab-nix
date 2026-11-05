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
          # Read-only key for the offsite copy (below).
          ${garage} key info offsite >/dev/null 2>&1 || ${garage} key create offsite
          ${garage} bucket allow --read cnpg --key offsite
        '';
      };

      # Offsite copy: the buckets, encrypted client-side (rclone crypt), to a Cloudflare R2
      # bucket (free tier: 10 GB), daily. Until the NAS takes over (design item 24).
      # A copy, not a replica: `sync` mirrors deletions, so barman's retention carries over;
      # R2 has no versioning. Restore: rclone copy offsite:cnpg back into Garage (or any S3).
      # Secrets (secrets/nuc1.yaml), all written by the owner: offsite-r2-endpoint
      # (https://<account id>.r2.cloudflarestorage.com), offsite-r2-bucket,
      # offsite-r2-key-id and offsite-r2-key-secret (an R2 API token scoped to that bucket,
      # Object Read & Write), offsite-crypt-password and offsite-crypt-salt (two long random
      # strings; losing them makes the copy unreadable, keep them in the password manager).
      sops.secrets = lib.genAttrs [
        "offsite-r2-endpoint" "offsite-r2-bucket" "offsite-r2-key-id" "offsite-r2-key-secret"
        "offsite-crypt-password" "offsite-crypt-salt" "garage-rpc-secret"
      ] (_: { });
      sops.templates."garage-offsite.env".content =
        let p = config.sops.placeholder; in ''
          RCLONE_CONFIG_R2_ENDPOINT=${p.offsite-r2-endpoint}
          RCLONE_CONFIG_R2_ACCESS_KEY_ID=${p.offsite-r2-key-id}
          RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=${p.offsite-r2-key-secret}
          R2_BUCKET=${p.offsite-r2-bucket}
          CRYPT_PASSWORD=${p.offsite-crypt-password}
          CRYPT_SALT=${p.offsite-crypt-salt}
        '';
      systemd.services.garage-offsite = {
        description = "Encrypted copy of the Garage buckets to Cloudflare R2";
        after = [ "garage-setup.service" ];
        requires = [ "garage-setup.service" ];
        path = [ pkgs.rclone pkgs.gawk ];
        environment = {
          RCLONE_CONFIG_GARAGE_TYPE = "s3";
          RCLONE_CONFIG_GARAGE_PROVIDER = "Other";
          RCLONE_CONFIG_GARAGE_ENDPOINT = "http://127.0.0.1:3900";
          RCLONE_CONFIG_GARAGE_REGION = "garage";
          RCLONE_CONFIG_R2_TYPE = "s3";
          RCLONE_CONFIG_R2_PROVIDER = "Cloudflare";
          # The token is scoped to one bucket: rclone must not try to create it.
          RCLONE_CONFIG_R2_NO_CHECK_BUCKET = "true";
          RCLONE_CONFIG_OFFSITE_TYPE = "crypt";
        };
        serviceConfig = {
          Type = "oneshot";
          EnvironmentFile = [
            config.sops.templates."garage.env".path
            config.sops.templates."garage-offsite.env".path
          ];
        };
        script = ''
          info=$(${garage} key info offsite --show-secret)
          export RCLONE_CONFIG_GARAGE_ACCESS_KEY_ID=$(echo "$info" | awk '/^Key ID:/ {print $3}')
          export RCLONE_CONFIG_GARAGE_SECRET_ACCESS_KEY=$(echo "$info" | awk '/^Secret key:/ {print $3}')
          export RCLONE_CONFIG_OFFSITE_REMOTE="R2:$R2_BUCKET"
          export RCLONE_CONFIG_OFFSITE_PASSWORD=$(rclone obscure "$CRYPT_PASSWORD")
          export RCLONE_CONFIG_OFFSITE_PASSWORD2=$(rclone obscure "$CRYPT_SALT")
          rclone sync GARAGE:cnpg OFFSITE:cnpg --transfers 4 --stats-one-line -v
        '';
      };
      systemd.timers.garage-offsite = {
        wantedBy = [ "timers.target" ];
        timerConfig = { OnCalendar = "daily"; RandomizedDelaySec = "1h"; Persistent = true; };
      };


      networking.firewall.extraCommands = lib.concatMapStrings
        (ip: "iptables -A nixos-fw -p tcp -s ${ip} --dport 3900 -j nixos-fw-accept\n")
        nodeIPs;
    };
}
