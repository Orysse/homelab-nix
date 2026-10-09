# Alerting on the monitoring host, below the cluster: it still fires when the cluster is
# down (D22). Standard split: vmalert evaluates the rules (_alert-rules.nix) against
# VictoriaMetrics, Alertmanager groups, silences and sends them by email through the
# homelab@<domain> mailbox. Grafana (in the cluster) only displays them.
#   vmalert       127.0.0.1:8880
#   Alertmanager  :9093  (the nodes may read it: Grafana's Alertmanager data source)
#   Heartbeat     Watchdog -> Healthchecks.io every minute; it emails if the pings stop
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.alerting = { config, lib, ... }:
    let
      domain = cluster.ingress.domain;
      nodeIPs = lib.filter (a: a != null) (lib.mapAttrsToList (_: n: n.address) cluster.nodes);
      mailbox = "homelab@${domain}";
    in
    lib.mkIf (cluster.monitoring.host == config.networking.hostName) {
      services.vmalert.instances.homelab = {
        enable = true;
        rules = import ./_alert-rules.nix { inherit domain; };
        settings = {
          "datasource.url" = "http://127.0.0.1:8428";
          "notifier.url" = [ "http://127.0.0.1:9093" ];
          # Alert state survives restarts: written to and read back from VictoriaMetrics.
          "remoteWrite.url" = "http://127.0.0.1:8428";
          "remoteRead.url" = "http://127.0.0.1:8428";
          "httpListenAddr" = "127.0.0.1:8880";
          "external.url" = "https://grafana.int.${domain}";
        };
      };

      sops.secrets.smtp-password = { };
      sops.secrets.heartbeat-url = { };   # Healthchecks.io ping URL (anyone with it can ping)
      services.prometheus.alertmanager = {
        enable = true;
        port = 9093;
        configuration = {
          global = {
            smtp_smarthost = "smtp.mail.ovh.net:465";   # implicit TLS
            smtp_from = "Homelab <${mailbox}>";
            smtp_auth_username = mailbox;
            smtp_auth_password_file = "/run/credentials/alertmanager.service/smtp-password";
          };
          route = {
            receiver = "email";
            group_by = [ "alertname" "host" "namespace" ];
            group_wait = "30s";
            group_interval = "5m";
            repeat_interval = "4h";
            # Watchdog always fires: its notification is a heartbeat to Healthchecks.io, which
            # emails when the pings stop (host down, internet down, alerting pipeline broken).
            routes = [{
              matchers = [ "alertname = Watchdog" ];
              receiver = "heartbeat";
              group_wait = "0s";
              group_interval = "1m";
              repeat_interval = "1m";
            }];
          };
          receivers = [
            {
              name = "heartbeat";
              webhook_configs = [{
                url_file = "/run/credentials/alertmanager.service/heartbeat-url";
                send_resolved = false;
              }];
            }
            {
              name = "email";
              email_configs = [{ to = mailbox; send_resolved = true; }];
            }
          ];
          # When the cluster sends nothing, its own alerts are noise: only the cause (and the
          # host alerts, which explain it) get through.
          inhibit_rules = [{
            source_matchers = [ "alertname = ClusterNotReporting" ];
            target_matchers = [ "alertname =~ KubeNodeNotReady|PodCrashLooping|DeploymentUnavailable|ContainerOOMKilled|FluxNotReady|StatusCheckFailing" ];
          }];
        };
      };
      # The password stays root-only; systemd hands a copy to the (dynamic) service user.
      systemd.services.alertmanager.serviceConfig.LoadCredential =
        [
        "smtp-password:${config.sops.secrets.smtp-password.path}"
        "heartbeat-url:${config.sops.secrets.heartbeat-url.path}"
      ];

      networking.firewall.extraCommands = lib.concatMapStrings
        (ip: "iptables -A nixos-fw -p tcp -s ${ip} --dport 9093 -j nixos-fw-accept\n")
        nodeIPs;
    };
}
