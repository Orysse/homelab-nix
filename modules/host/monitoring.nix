# Monitoring backends on the monitoring host, below the cluster: they keep working, and
# keep the history, when the cluster is broken (D22).
#   VictoriaMetrics :8428  metrics (Prometheus API), pushed by Alloy in the cluster,
#                          scrapes this host's exporters itself
#   VictoriaLogs    :9428  logs, pushed by Alloy and by systemd-journal-upload (journald)
# Alerting: alerting.nix (vmalert + Alertmanager). Dashboards: Grafana, in the cluster.
# Both ports only accept the nodes; the exporters listen on localhost.
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.monitoring = { config, lib, pkgs, ... }:
    let
      domain = cluster.ingress.domain;
      host = config.networking.hostName;
      nodeIPs = lib.filter (a: a != null) (lib.mapAttrsToList (_: n: n.address) cluster.nodes);
      fromNodes = port: lib.concatMapStrings
        (ip: "iptables -A nixos-fw -p tcp -s ${ip} --dport ${toString port} -j nixos-fw-accept\n")
        nodeIPs;
      # WireGuard exporter: peers named after the topology, not their public key.
      wgNames = pkgs.writeText "wg0-names.conf" (lib.concatStrings (lib.mapAttrsToList (name: peer: ''
        [Peer]
        # friendly_name = ${name}
        PublicKey = ${peer.publicKey}
        AllowedIPs = ${peer.address}/32
      '') cluster.vpn.peers));
    in
    lib.mkIf (cluster.monitoring.host == host) {
      services.victoriametrics = {
        enable = true;
        listenAddress = ":8428";
        retentionPeriod = "90d";
        # One job per exporter on this host; "host" tells hosts apart once there are several.
        prometheusConfig.scrape_configs = lib.mapAttrsToList (job: port: {
          job_name = job;
          static_configs = [{ targets = [ "127.0.0.1:${toString port}" ]; labels.host = host; }];
        }) {
          node = 9100;            # incl. systemd units
          wireguard = 9586;
          smartctl = 9633;
          victoriametrics = 8428;
          victorialogs = 9428;
          vmalert = 8880;
          alertmanager = 9093;
        };
      };

      services.victorialogs = {
        enable = true;
        listenAddress = ":9428";
        extraOptions = [ "-retentionPeriod=30d" ];
      };

      # This host's journal, straight into VictoriaLogs (no agent).
      services.journald.upload = {
        enable = true;
        settings.Upload.URL = "http://127.0.0.1:9428/insert/journald";
      };
      systemd.services.systemd-journal-upload = {
        after = [ "victorialogs.service" ];
        wants = [ "victorialogs.service" ];
      };

      services.prometheus.exporters = {
        node = {
          enable = true;
          listenAddress = "127.0.0.1";
          enabledCollectors = [ "systemd" ];
          extraFlags = [
            # Units worth watching: the VMs and what the host serves.
            "--collector.systemd.unit-include=(microvm.*|sshd|systemd-networkd|ddclient|nfs-server|btrbk-.*|victoria.*|vmalert-.*|alertmanager|systemd-journal-upload)\\.(service|timer)"
          ];
        };
        wireguard = {
          enable = true;
          listenAddress = "127.0.0.1";
          wireguardConfig = "${wgNames}";
        };
        smartctl = {
          enable = true;
          listenAddress = "127.0.0.1";
        };
      };

      networking.firewall.extraCommands = fromNodes 8428 + fromNodes 9428;
    };
}
