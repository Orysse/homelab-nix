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
                };
            };
          };
        };
      };
    };
  };
}
