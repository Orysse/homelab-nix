{ config, inputs, ... }:
let
  m = config.flake.modules.nixos;
in
{
  flake.nixosConfigurations.nuc1 = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      ../../hardware/nuc1.nix
      m.base
      m.boot
      m.users-ssh
      m.disk-layout
      m.network-bridge
      # m.wifi-uplink  # uplink Wi-Fi temporaire (iwd + NAT), désactivé
      m.cluster-assertions
      m.microvm-host
      m.k3s-token
      {
        networking.hostName = "nuc1";
        homelab.diskDevice = "/dev/disk/by-id/nvme-KINGSTON_SNVS500G_50026B7685AD8136";
        # e1000e intégrée. Pas "en*" : un adaptateur USB (cdc_ncm) serait aussi ponté.
        homelab.lanInterface = "eno1";
        # Avec wifi-uplink. Nom noyau : iwd fournit 80-iwd.link (NamePolicy=keep kernel).
        # homelab.wifiInterface = "wlan0";
      }
    ];
  };
}
