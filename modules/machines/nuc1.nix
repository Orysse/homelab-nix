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
      m.tailscale
      m.storage
      m.monitoring
      m.alerting
      m.postgres
      ({ pkgs, ... }: {
        networking.hostName = "nuc1";
        homelab.diskDevice = "/dev/disk/by-id/nvme-KINGSTON_SNVS500G_50026B7685AD8136";
        # Not "en*": a USB adapter (cdc_ncm) would be bridged too.
        homelab.lanInterface = "eno1";

        # CPU power limits: the BIOS defaults (PL1 30 W, PL2 64 W, tau 28 s). They were capped at
        # 25 W in software while nuc1 ran on a 65 W supply, which cut out on CPU bursts
        # (2026-10-09); a new supply replaced it on 2026-10-11.

        # Intel I219 (e1000e) "Detected Hardware Unit Hang" under load (NFS, VM traffic on the
        # bridge): the NIC stopped for good on 2026-10-09 and nuc1 went offline for 20 minutes.
        # Known e1000e bug with segmentation offload; the usual fix is to turn it off.
        systemd.services.lan-nic-offload = {
          description = "Disable TSO/GSO on the LAN NIC (e1000e hangs)";
          wantedBy = [ "multi-user.target" ];
          bindsTo = [ "sys-subsystem-net-devices-eno1.device" ];
          after = [ "sys-subsystem-net-devices-eno1.device" ];
          serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
          script = "${pkgs.ethtool}/bin/ethtool -K eno1 tso off gso off";
        };
      })
    ];
  };
}
