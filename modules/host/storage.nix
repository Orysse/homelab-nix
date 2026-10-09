# The storage host: all the cluster's persistent data lives here, on the btrfs subvolume
# @data (disk-layout.nix), exported over NFSv4 to the nodes only. The VMs keep no state, so
# they stay disposable. In the cluster: csi-driver-nfs, StorageClass "nfs", one directory
# per volume (<namespace>_<pvc>).
# Snapshots: btrbk, hourly, read-only, in the top-level subvolume @snapshots (outside @data).
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.storage = { config, lib, ... }:
    let
      nodeIPs = lib.filter (a: a != null) (lib.mapAttrsToList (_: n: n.address) cluster.nodes);
      path = cluster.storage.path;
    in
    lib.mkIf (cluster.storage.host == config.networking.hostName) {
      services.nfs.server = {
        enable = true;
        # no_root_squash: the CSI controller creates and deletes volume directories as root;
        # ownership inside a volume follows the pod's fsGroup.
        exports = lib.concatMapStrings
          (ip: "${path} ${ip}(rw,sync,no_subtree_check,no_root_squash,sec=sys)\n")
          nodeIPs;
      };
      # NFSv4 only: a single TCP port, no rpcbind / mountd exposure.
      services.nfs.settings.nfsd = { vers3 = false; "vers4.0" = false; };

      networking.firewall.extraCommands = lib.concatMapStrings
        (ip: "iptables -A nixos-fw -p tcp -s ${ip} --dport 2049 -j nixos-fw-accept\n")
        nodeIPs;

      # btrbk works on the top level of the filesystem: @data is snapshotted into @snapshots.
      fileSystems."/mnt/btrfs" = {
        device = config.fileSystems."/".device;
        fsType = "btrfs";
        options = [ "subvolid=5" "noatime" ];
      };
      systemd.services.btrbk-data.unitConfig.RequiresMountsFor = [ "/mnt/btrfs" ];

      services.btrbk.instances.data = {
        onCalendar = "hourly";
        settings = {
          timestamp_format = "long";
          snapshot_preserve_min = "6h";
          snapshot_preserve = "48h 14d 8w";
          volume."/mnt/btrfs" = {
            snapshot_dir = "@snapshots";
            subvolume."@data" = { };
          };
        };
      };
    };
}
