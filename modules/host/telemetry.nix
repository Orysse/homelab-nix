# What every host reports: node and SMART exporters on the host's address, scraped by the
# monitoring host (monitoring.nix), and the host's journal pushed to VictoriaLogs there. The
# firewall lets only the monitoring host reach the exporters. The wireguard exporter lives in
# wireguard.nix (vpn), the bouncer's in crowdsec-bouncer.nix.
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.telemetry = { config, lib, pkgs, ... }:
    let
      clusterLib = import ../topology/_lib.nix { inherit lib; };
      address = clusterLib.hostAddress cluster config.networking.hostName;
      monitor = clusterLib.hostAddress cluster (clusterLib.hostOf cluster "monitoring");
      fromMonitor = port:
        "iptables -A nixos-fw -p tcp -s ${monitor} --dport ${toString port} -j nixos-fw-accept\n";
      # The exporters bind the host's address: wait for br0 to have it.
      afterNetwork = { after = [ "network-online.target" ]; wants = [ "network-online.target" ]; };
    in
    {
      services.prometheus.exporters = {
        node = {
          enable = true;
          listenAddress = address;
          enabledCollectors = [ "systemd" ];
          extraFlags = [
            # Units worth watching: the VMs and what the host serves.
            "--collector.systemd.unit-include=(microvm.*|sshd|systemd-networkd|ddclient|nfs-server|btrbk-.*|victoria.*|vmalert-.*|alertmanager|trivy-scan|systemd-journal-upload)\\.(service|timer)"
          ];
        };
        smartctl = {
          enable = true;
          listenAddress = address;
        };
      };
      systemd.services.prometheus-node-exporter = afterNetwork;
      systemd.services.prometheus-smartctl-exporter = afterNetwork;

      # Power use (node_rapl_*, for cost estimates): the kernel makes the RAPL energy counters
      # root-only (a side channel); the node exporter's group may read them. On the NUC10,
      # "psys" (the whole platform) is the trustworthy zone; "package" reads high.
      services.udev.extraRules = ''
        ACTION=="add", SUBSYSTEM=="powercap", KERNEL=="intel-rapl:*", RUN+="${pkgs.coreutils}/bin/chgrp node-exporter /sys%p/energy_uj", RUN+="${pkgs.coreutils}/bin/chmod g+r /sys%p/energy_uj"
      '';

      # This host's journal, straight into VictoriaLogs on the monitoring host (no agent).
      services.journald.upload = {
        enable = true;
        settings.Upload.URL = "http://${monitor}:9428/insert/journald";
      };

      networking.firewall.extraCommands = fromMonitor 9100 + fromMonitor 9633;
    };
}
