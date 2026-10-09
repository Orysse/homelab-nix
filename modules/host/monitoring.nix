# Monitoring backends on the monitoring host, below the cluster: they keep working, and
# keep the history, when the cluster is broken (D22).
#   VictoriaMetrics :8428  metrics (Prometheus API), pushed by Alloy in the cluster,
#                          scrapes this host's exporters itself
#   VictoriaLogs    :9428  logs, pushed by Alloy and by systemd-journal-upload (journald)
#   Grafana         :3000  dashboards and alerts (email through homelab@<domain>),
#                          routed at grafana.int.<domain> by the cluster's internal Gateway
# The three ports only accept the nodes; on the host itself everything is on localhost.
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
      secret = name: "$__file{${config.sops.secrets.${name}.path}}";

      # WireGuard exporter: peers named after the topology, not their public key.
      wgNames = pkgs.writeText "wg0-names.conf" (lib.concatStrings (lib.mapAttrsToList (name: peer: ''
        [Peer]
        # friendly_name = ${name}
        PublicKey = ${peer.publicKey}
        AllowedIPs = ${peer.address}/32
      '') cluster.vpn.peers));

      dashboards = pkgs.linkFarm "grafana-dashboards" [
        {
          name = "node-exporter-full.json";
          path = pkgs.fetchurl {
            url = "https://grafana.com/api/dashboards/1860/revisions/45/download";
            hash = "sha256-GExrdAnzBtp1Ul13cvcZRbEM6iOtFrXXjEaY6g6lGYY=";
          };
        }
      ];
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
          grafana = 3000;
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
            "--collector.systemd.unit-include=(microvm.*|sshd|systemd-networkd|ddclient|nfs-server|btrbk-.*|victoria.*|grafana|systemd-journal-upload)\\.(service|timer)"
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

      sops.secrets = lib.mkIf config.services.grafana.enable (lib.genAttrs [ "grafana-admin-password" "grafana-secret-key" "smtp-password" ]
        (_: { owner = "grafana"; }));

      services.grafana = {
        enable = true;
        # Grafana 13 ships Prometheus as a separate plugin; VictoriaMetrics speaks its API.
        declarativePlugins = with pkgs.grafanaPlugins; [ prometheus victoriametrics-logs-datasource ];
        settings = {
          server = {
            http_addr = "0.0.0.0";
            http_port = 3000;
            domain = "grafana.int.${domain}";
            root_url = "https://grafana.int.${domain}/";
          };
          security = {
            admin_user = "admin";
            admin_password = secret "grafana-admin-password";
            secret_key = secret "grafana-secret-key";
            cookie_secure = true;
          };
          users.allow_sign_up = false;
          analytics = { reporting_enabled = false; check_for_updates = false; };
          smtp = {
            enabled = true;
            host = "smtp.mail.ovh.net:465";   # implicit TLS
            startTLS_policy = "NoStartTLS";
            user = "homelab@${domain}";
            password = secret "smtp-password";
            from_address = "homelab@${domain}";
            from_name = "Homelab";
          };
        };
        provision = {
          enable = true;
          datasources.settings.datasources = [
            {
              name = "VictoriaMetrics";
              uid = "victoriametrics";
              type = "prometheus";
              url = "http://127.0.0.1:8428";
              isDefault = true;
            }
            {
              name = "VictoriaLogs";
              uid = "victorialogs";
              type = "victoriametrics-logs-datasource";
              url = "http://127.0.0.1:9428";
            }
          ];
          dashboards.settings.providers = [{
            name = "homelab";
            options.path = dashboards;
            allowUiUpdates = false;
          }];
        };
      };

      networking.firewall.extraCommands = fromNodes 8428 + fromNodes 9428 + fromNodes 3000;
    };
}
