# Monitoring backends on the monitoring host, below the cluster: they keep working, and
# keep the history, when the cluster is broken (D22).
#   VictoriaMetrics :8428  metrics (Prometheus API), pushed by the collector in the cluster,
#                          scrapes every host's exporters itself (telemetry.nix)
#   VictoriaLogs    :9428  logs, pushed by the collector and by every host's journal upload
# Alerting: alerting.nix (vmalert + Alertmanager). Dashboards: Grafana, in the cluster.
# 8428 only accepts the k3s VMs; 9428 also accepts the hosts.
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.monitoring = { config, lib, ... }:
    let
      clusterLib = import ../topology/_lib.nix { inherit lib; };
      host = config.networking.hostName;
      address = clusterLib.hostAddress cluster;
      hostNames = lib.attrNames cluster.hosts;
      fromIPs = ips: port: lib.concatMapStrings
        (ip: "iptables -A nixos-fw -p tcp -s ${ip} --dport ${toString port} -j nixos-fw-accept\n")
        ips;
      vmIPs = clusterLib.vmIPs cluster;
      hostIPs = map address hostNames;

      # One job per exporter, one target per host that runs it; "host" tells hosts apart.
      onHosts = port: hosts: map (h: { targets = [ "${address h}:${toString port}" ]; labels.host = h; }) hosts;
      k3sHosts = lib.filter (h: clusterLib.k3sVmOf cluster h != null) hostNames;
      local = port: [{ targets = [ "127.0.0.1:${toString port}" ]; labels.host = host; }];
      jobs = {
        node = onHosts 9100 hostNames;                                       # incl. systemd units
        smartctl = onHosts 9633 hostNames;
        wireguard = onHosts 9586 [ (clusterLib.hostOf cluster "vpn") ];      # wireguard.nix
        crowdsec-firewall-bouncer = onHosts 60601 k3sHosts;                  # crowdsec-bouncer.nix
        victoriametrics = local 8428;
        victorialogs = local 9428;
        vmalert = local 8880;
        alertmanager = local 9093;
      };
    in
    {
      services.victoriametrics = {
        enable = true;
        listenAddress = ":8428";
        retentionPeriod = "90d";
        prometheusConfig.scrape_configs = lib.mapAttrsToList
          (job_name: static_configs: { inherit job_name static_configs; })
          jobs;
      };

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

      networking.firewall.extraCommands = fromIPs vmIPs 8428 + fromIPs (vmIPs ++ hostIPs) 9428;
    };
}
