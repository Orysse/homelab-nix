# One btrfs pool rather than partitions: no size to fix upfront. Separate subvolumes so
# @root can be restored without touching the store, the logs or the VMs' state.
{ inputs, ... }:
{
  flake.modules.nixos.disk-layout = { config, lib, ... }: {
    imports = [ inputs.disko.nixosModules.disko ];

    options.homelab.diskDevice = lib.mkOption {
      type = lib.types.str;
      description = "System disk (preferably /dev/disk/by-id/…).";
    };

    # nocow: SeaweedFS checksums its own needles, and its append-and-compact files fragment
    # under copy-on-write. Applies to files created afterwards.
    config.systemd.tmpfiles.settings."20-seaweed"."/srv/seaweed".h.argument = "+C";

    config.disko.devices.disk.main = {
      type = "disk";
      device = config.homelab.diskDevice;
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            priority = 1;
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          system = {
            size = "100%";
            content = {
              type = "btrfs";
              extraArgs = [ "-f" "-L" "nixos" ];
              subvolumes =
                let opts = [ "compress=zstd" "noatime" ];
                in {
                  "/@root" = { mountpoint = "/"; mountOptions = opts; };
                  "/@nix" = { mountpoint = "/nix"; mountOptions = opts; };
                  "/@log" = { mountpoint = "/var/log"; mountOptions = opts; };
                  "/@microvms" = { mountpoint = "/var/lib/microvms"; mountOptions = opts; };
                  # SeaweedFS volume data (phase 4): shared with the k3s VM, not snapshotted.
                  "/@seaweed" = { mountpoint = "/srv/seaweed"; mountOptions = opts; };
                  # OpenBao data: snapshotted hourly (snapshots.nix), shared with the k3s VM.
                  "/@openbao" = { mountpoint = "/srv/openbao"; mountOptions = opts; };
                  "/@snapshots" = { };   # btrbk snapshots (snapshots.nix), not mounted
                };
            };
          };
        };
      };
    };
  };
}
