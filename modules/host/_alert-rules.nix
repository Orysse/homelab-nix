# Alert rules evaluated by vmalert on the monitoring host (alerting.nix), against
# VictoriaMetrics. Imported by alerting.nix (the "_" prefix keeps import-tree away).
# severity: critical (act now) / warning (look today). Every alert says what to check.
{ domain }:
let
  alert = name: expr: for: severity: summary: description: {
    alert = name;
    inherit expr for;
    labels = { inherit severity; };
    annotations = { inherit summary description; };
  };
in
{
  groups = [
    {
      name = "host";
      rules = [
        (alert "HostRestarted"
          "time() - node_boot_time_seconds{job=\"node\"} < 900"
          "0m" "warning"
          "{{ $labels.host }} restarted"
          "{{ $labels.host }} booted less than 15 minutes ago. Unplanned? Check the power supply, then `journalctl -b -1 | tail`.")
        (alert "HostUnitInactive"
          "node_systemd_unit_state{job=\"node\",state=\"active\",name=~\"microvm@.+|microvm-virtiofsd@.+|sshd.service|systemd-networkd.service|nfs-server.service|victoria.+|vmalert.+|alertmanager.service|ddclient.timer|btrbk-data.timer\"} == 0"
          "5m" "critical"
          "{{ $labels.host }}: {{ $labels.name }} is not active"
          "`systemctl status {{ $labels.name }}` and `journalctl -u {{ $labels.name }} -n 50` on {{ $labels.host }}.")
        (alert "HostDiskFilling"
          "1 - node_filesystem_avail_bytes{job=\"node\",fstype=\"btrfs\"} / node_filesystem_size_bytes{job=\"node\",fstype=\"btrfs\"} > 0.85"
          "30m" "warning"
          "{{ $labels.host }}: {{ $labels.mountpoint }} is {{ $value | humanizePercentage }} full"
          "Old generations (`nix-collect-garbage -d`), journals, btrbk snapshots, VM data volumes.")
        (alert "HostSmartFailing"
          "smartctl_device_smart_status == 0"
          "0m" "critical"
          "{{ $labels.host }}: disk {{ $labels.device }} reports a SMART failure"
          "The disk itself says it is failing. Check backups first, then `smartctl -a /dev/{{ $labels.device }}`.")
        (alert "MemoryLow"
          "node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.1"
          "15m" "warning"
          "{{ $labels.host }}{{ $labels.node }}: less than 10% memory available"
          "VM sizes are in topology.nix; `kubectl top pods -A --sort-by=memory` for the cluster.")
      ];
    }
    {
      name = "cluster";
      rules = [
        (alert "ClusterNotReporting"
          "absent(up{job=\"kubelet\"} == 1)"
          "10m" "critical"
          "The cluster sends no metrics"
          "No kubelet scraped for 10 minutes: VMs down, Alloy down, or the network between them and the monitoring host.")
        (alert "KubeNodeNotReady"
          "kube_node_status_condition{condition=\"Ready\",status=\"true\"} == 0"
          "10m" "critical"
          "Node {{ $labels.node }} is NotReady"
          "Is its VM running (HostUnitInactive)? `kubectl describe node {{ $labels.node }}`.")
        (alert "PodCrashLooping"
          "max_over_time(kube_pod_container_status_waiting_reason{reason=\"CrashLoopBackOff\"}[5m]) >= 1"
          "10m" "warning"
          "{{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }}) is crash-looping"
          "`kubectl -n {{ $labels.namespace }} logs {{ $labels.pod }} -c {{ $labels.container }} --previous`.")
        (alert "DeploymentUnavailable"
          "kube_deployment_status_replicas_unavailable > 0"
          "15m" "warning"
          "{{ $labels.namespace }}/{{ $labels.deployment }} is missing replicas"
          "Image pull, probes or scheduling: `kubectl -n {{ $labels.namespace }} describe deploy {{ $labels.deployment }}`.")
        (alert "ContainerOOMKilled"
          "increase(kube_pod_container_status_restarts_total[15m]) > 0 and on (namespace, pod, container) kube_pod_container_status_last_terminated_reason{reason=\"OOMKilled\"} == 1"
          "0m" "warning"
          "{{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }}) was OOM-killed"
          "Its memory limit is too low, or it leaks. Compare with `resources.limits.memory`.")
      ];
    }
    {
      name = "gitops";
      rules = [
        (alert "FluxNotReady"
          "gotk_resource_info{ready=\"False\"} == 1"
          "15m" "warning"
          "Flux {{ $labels.customresource_kind }} {{ $labels.name }} is not ready"
          "Git is not being applied. `flux get all -A`, `flux events -A --types=Warning` (docs/cheatsheet.md).")
      ];
    }
    {
      name = "apps";
      rules = [
        (alert "StatusCheckFailing"
          "gatus_results_endpoint_success == 0"
          "5m" "critical"
          "{{ $labels.name }} is failing its status check"
          "See https://status.${domain}: wrong status, slow, DNS, or certificate expiring in under 14 days.")
        (alert "CertificateExpiring"
          "certmanager_certificate_expiration_timestamp_seconds - time() < 14 * 86400"
          "1h" "warning"
          "Certificate {{ $labels.namespace }}/{{ $labels.name }} expires in under 14 days"
          "cert-manager should have renewed it 30 days before: `kubectl -n {{ $labels.namespace }} describe certificate {{ $labels.name }}`.")
      ];
    }
    {
      # Always firing. Alertmanager routes it to nobody for now; later to an external
      # heartbeat that alerts when it STOPS (monitoring host dead, power cut).
      name = "meta";
      rules = [
        (alert "Watchdog" "vector(1)" "0m" "none"
          "Alerting pipeline is alive"
          "Always firing on purpose.")
      ];
    }
  ];
}
