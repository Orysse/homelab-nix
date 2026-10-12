# Vulnerability scan of the images running in the cluster, on the monitoring host (D22): it
# costs the cluster nothing, and nuc1 has the memory a scan needs. Daily:
#   1. the running images, from VictoriaMetrics (kube-state-metrics' kube_pod_container_info):
#      no access to the cluster needed
#   2. Trivy scans each one from its registry (remote: no container runtime here); its
#      vulnerability database stays cached between runs
#   3. counts per image and severity, all and fixable, go to the node exporter's textfile
#      collector -> VictoriaMetrics -> Grafana and alerts (_alert-rules.nix, group "security")
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.trivy = { config, lib, pkgs, ... }:
    let
      textfileDir = "/var/lib/trivy-metrics";
      scan = pkgs.writeShellApplication {
        name = "trivy-scan-cluster";
        runtimeInputs = [ pkgs.trivy pkgs.curl pkgs.jq pkgs.coreutils ];
        text = ''
          out="${textfileDir}/trivy.prom"
          tmp="$(mktemp)"
          curl -fsS http://127.0.0.1:8428/api/v1/query \
              --data-urlencode 'query=count by (image_spec) (kube_pod_container_info)' |
            jq -r '.data.result[].metric.image_spec' | sort -u > images.txt
          {
            echo "# HELP trivy_image_vulnerabilities Vulnerabilities in a running image, by severity."
            echo "# TYPE trivy_image_vulnerabilities gauge"
            echo "# HELP trivy_image_vulnerabilities_fixable Those with a fixed version available."
            echo "# TYPE trivy_image_vulnerabilities_fixable gauge"
            echo "# HELP trivy_image_scan_success 1 if the last scan of the image succeeded."
            echo "# TYPE trivy_image_scan_success gauge"
          } > "$tmp"
          while read -r ref; do
            image="''${ref%@*}"            # the digest makes labels unreadable
            if trivy image --quiet --no-progress --image-src remote --scanners vuln \
                --skip-java-db-update --timeout 15m --format json \
                --cache-dir "$CACHE_DIRECTORY" "$ref" > report.json 2> error.log; then
              jq -r --arg img "$image" '
                [.Results[]?.Vulnerabilities[]?] as $v
                | ["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"][] as $s
                | ($v | map(select(.Severity == $s))) as $x
                | "trivy_image_vulnerabilities{image=\"\($img)\",severity=\"\($s)\"} \($x | length)",
                  "trivy_image_vulnerabilities_fixable{image=\"\($img)\",severity=\"\($s)\"} \($x | map(select((.FixedVersion // "") != "")) | length)"
              ' report.json >> "$tmp"
              echo "trivy_image_scan_success{image=\"$image\"} 1" >> "$tmp"
            else
              echo "scan failed: $ref: $(tail -1 error.log)" >&2
              echo "trivy_image_scan_success{image=\"$image\"} 0" >> "$tmp"
            fi
          done < images.txt
          echo "trivy_last_run_timestamp_seconds $(date +%s)" >> "$tmp"
          chmod 0644 "$tmp"
          mv "$tmp" "$out"
        '';
      };
    in
    lib.mkIf (cluster.monitoring.host == config.networking.hostName) {
      users.users.trivy = { isSystemUser = true; group = "trivy"; };
      users.groups.trivy = { };

      systemd.services.trivy-scan = {
        description = "Scan the cluster's running images for vulnerabilities";
        after = [ "network-online.target" "victoriametrics.service" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe scan;
          # A fixed user, not DynamicUser: its state directory would sit under the 0700
          # /var/lib/private, out of the node exporter's reach.
          User = "trivy";
          Group = "trivy";
          CacheDirectory = "trivy";            # vulnerability database, image layers
          StateDirectory = "trivy-metrics";    # read by the node exporter
          StateDirectoryMode = "0755";
          WorkingDirectory = "/tmp";
          PrivateTmp = true;
          # Below everything else: VictoriaMetrics, PostgreSQL, the VMs.
          Nice = 19;
          IOSchedulingClass = "idle";
          MemoryMax = "1500M";
        };
      };
      systemd.timers.trivy-scan = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*-*-* 04:30";
          RandomizedDelaySec = "30m";
          Persistent = true;                   # catch up after a reboot
        };
      };

      services.prometheus.exporters.node = {
        enabledCollectors = [ "textfile" ];
        extraFlags = [ "--collector.textfile.directory=${textfileDir}" ];
      };
    };
}
