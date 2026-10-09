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
      m.cluster-assertions
      m.microvm-host
      m.k3s-token
      m.secrets
      m.ddns
      m.datadog
      m.wireguard
      m.storage
      {
        networking.hostName = "nuc1";
        homelab.diskDevice = "/dev/disk/by-id/nvme-KINGSTON_SNVS500G_50026B7685AD8136";
        # Not "en*": a USB adapter (cdc_ncm) would be bridged too.
        homelab.lanInterface = "eno1";
      }
    ];
  };
}
