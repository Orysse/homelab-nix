# The log store on the monitoring host, below the cluster: it keeps working, and keeps the
# history, when the cluster is broken (D22).
#   VictoriaLogs :9428  logs, pushed by the collector in the cluster and by every host's
#                       journal upload (telemetry.nix); read with its own UI, vmui, over an
#                       SSH tunnel: ssh -L 9428:127.0.0.1:9428 nuc1, then
#                       http://localhost:9428/select/vmui
# Host metrics and their alerts are Beszel's (beszel.nix); the dead-man's switch is heartbeat.nix.
# 9428 accepts the k3s VMs and the hosts.
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.monitoring = { config, lib, ... }:
    let
      clusterLib = import ../topology/_lib.nix { inherit lib; };
      address = clusterLib.hostAddress cluster;
      fromIPs = ips: port: lib.concatMapStrings
        (ip: "iptables -A nixos-fw -p tcp -s ${ip} --dport ${toString port} -j nixos-fw-accept\n")
        ips;
      vmIPs = clusterLib.vmIPs cluster;
      hostIPs = map address (lib.attrNames cluster.hosts);
    in
    {
      services.victorialogs = {
        enable = true;
        listenAddress = ":9428";
        extraOptions = [ "-retentionPeriod=30d" ];
      };

      # This host's journal upload (telemetry.nix) starts after the backend it pushes to.
      systemd.services.systemd-journal-upload = {
        after = [ "victorialogs.service" ];
        wants = [ "victorialogs.service" ];
      };

      networking.firewall.extraCommands = fromIPs (vmIPs ++ hostIPs) 9428;
    };
}
