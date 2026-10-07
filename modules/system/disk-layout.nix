# Disque unique : ESP + un btrfs découpé en sous-volumes.
#
#   @root      -> /                  système (reconstructible, snapshotable seul)
#   @nix       -> /nix               store, gros et 100 % reproductible
#   @log       -> /var/log           les logs ne remplissent pas / et survivent à un rollback de @root
#   @microvms  -> /var/lib/microvms  état des VMs (identité SSH) et, en phase 2, volumes Longhorn
#
# Un seul pool btrfs plutôt que des partitions fixes : pas de taille à deviner,
# l'espace libre est commun à tous les sous-volumes.
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
