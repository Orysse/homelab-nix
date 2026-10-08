# Un pool btrfs plutôt que des partitions : pas de taille à figer. Sous-volumes séparés
# pour restaurer @root sans toucher au store, aux logs ni à l'état des VMs.
{ inputs, ... }:
{
  flake.modules.nixos.disk-layout = { config, lib, ... }: {
    imports = [ inputs.disko.nixosModules.disko ];

    options.homelab.diskDevice = lib.mkOption {
      type = lib.types.str;
      description = "Disque système (de préférence /dev/disk/by-id/…).";
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
