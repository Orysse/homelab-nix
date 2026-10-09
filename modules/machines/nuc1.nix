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
      m.wireguard
      m.storage
      m.monitoring
      {
        networking.hostName = "nuc1";
        homelab.diskDevice = "/dev/disk/by-id/nvme-KINGSTON_SNVS500G_50026B7685AD8136";
        # Not "en*": a USB adapter (cdc_ncm) would be bridged too.
        homelab.lanInterface = "eno1";

        # 65 W power supply (Intel ships 90 W with the NUC10i7FNH): CPU bursts (PL2 45 W in the
        # BIOS) plus the rest of the board reach ~65 W and the PSU cuts out (seen twice during a
        # switch, 2026-10-09). PL2 = PL1 = 25 W: same sustained power, no spikes.
        services.undervolt = {
          enable = true;
          p1 = { limit = 25; window = 28; };
          p2 = { limit = 25; window = 0.00244; };
          useTimer = true;   # re-applied periodically, in case the firmware resets it
        };
      }
    ];
  };
}
