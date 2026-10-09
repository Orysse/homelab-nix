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
      m.alerting
      m.postgres
      ({ pkgs, ... }: {
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
        # The timer rewrites the power-limit MSR every ~30 s; without this the kernel logs a
        # warning each time.
        boot.kernelParams = [ "msr.allow_writes=on" ];

        # Intel I219 (e1000e) "Detected Hardware Unit Hang" under load (NFS, VM traffic on the
        # bridge): the NIC stopped for good on 2026-10-09 and nuc1 went offline for 20 minutes.
        # Known e1000e bug with segmentation offload; the usual fix is to turn it off.
        systemd.services.lan-nic-offload = {
          description = "Disable TSO/GSO on the LAN NIC (e1000e hangs)";
          wantedBy = [ "sys-subsystem-net-devices-eno1.device" ];
          bindsTo = [ "sys-subsystem-net-devices-eno1.device" ];
          after = [ "sys-subsystem-net-devices-eno1.device" ];
          serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
          script = "${pkgs.ethtool}/bin/ethtool -K eno1 tso off gso off";
        };
      })
    ];
  };
}
