# Hourly read-only btrfs snapshots of the data that cannot be rebuilt, in the top-level
# subvolume @snapshots (outside what they copy). A btrfs snapshot is atomic: a database
# restored from one recovers like after a crash. Modules that own such data register their
# subvolume on this instance (postgres.nix, garage.nix, storage.nix).
# The OpenBao data (@openbao) is shared with the k3s VM (virtiofs, microvm-guest.nix); the
# daily offsite copy of its latest snapshot is garage.nix.
{ ... }:
{
  flake.modules.nixos.snapshots = { config, ... }: {
    # btrbk works on the top level of the filesystem.
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
          subvolume."@openbao" = { };
        };
      };
    };

    # Owned by the uid/gid OpenBao runs as in its pod (100:1000); the data is placed there
    # by hand once (docs/runbooks, OpenBao move).
    systemd.tmpfiles.settings."20-openbao"."/srv/openbao".d = { user = "root"; group = "1000"; mode = "2775"; };
  };
}
