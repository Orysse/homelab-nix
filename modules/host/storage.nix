# The storage host: all the cluster's persistent data lives here, on the btrfs subvolume
# @data (disk-layout.nix), exported over NFSv4 to the nodes only. The VMs keep no state, so
# they stay disposable. In the cluster: csi-driver-nfs, StorageClass "nfs", one directory
# per volume (<namespace>_<pvc>).
# Snapshots: snapshots.nix (btrbk, hourly, @snapshots).
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.storage = { config, lib, ... }:
    let
      clusterLib = import ../topology/_lib.nix { inherit lib; };
      nodeIPs = clusterLib.vmIPs cluster;
      path = cluster.storage.path;
    in
    {
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

      # Snapshots: snapshots.nix; @data is registered on its btrbk instance.
      services.btrbk.instances.data.settings.volume."/mnt/btrfs".subvolume."@data" = { };
    };
}
