# What the homelab draws from the wall, and what it costs: a software estimate, recorded by
# vmalert on the monitoring host (alerting.nix), tested by power.nix.
#   host       RAPL (CPU package + DRAM, node exporter on the host) + a constant for the rest
#              of the machine (SSD, board, NIC, power supply losses), not measured
#   VM         the host's RAPL watts times the VM's share of the host's busy CPU
#   namespace  the VM's watts times the namespace's share of the VM's busy CPU (cAdvisor)
#   cost       host watts over a month (730 h) at one flat price per kWh
# One physical host for now: the VM and namespace splits use the host's totals as scalars.
let
  # nuc1 at the wall minus its RAPL reading, idle: about 5 W (a NUC board, one NVMe SSD,
  # one NIC, the power supply's losses). An estimate, shown as such on the dashboard.
  baseWatts = 5;
  # Flat price of the electricity contract, €/kWh. Change it when the contract changes.
  kwhPriceEur = 0.25;
  busy = ''mode!~"idle|iowait|steal"'';
  rapl = ''{__name__=~"node_rapl_(package|dram)_joules_total", job="node"}'';
in
{
  name = "power";
  rules = [
    {
      record = "homelab:host_power_watts";
      expr = "sum by (host) (rate(${rapl}[5m])) + ${toString baseWatts}";
    }
    {
      record = "homelab:vm_power_watts";
      expr = ''
        sum by (node) (rate(node_cpu_seconds_total{job="prometheus-node-exporter", ${busy}}[5m]))
          / scalar(sum(rate(node_cpu_seconds_total{job="node", ${busy}}[5m])))
          * scalar(sum(rate(${rapl}[5m])))
      '';
    }
    {
      record = "homelab:namespace_power_watts";
      expr = ''
        sum by (node, namespace) (label_replace(
            rate(container_cpu_usage_seconds_total{job="cadvisor", container!="", container!="POD"}[5m]),
            "node", "$1", "instance", "(.*)"))
          / on (node) group_left
            sum by (node) (rate(node_cpu_seconds_total{job="prometheus-node-exporter", ${busy}}[5m]))
          * on (node) group_left homelab:vm_power_watts
      '';
    }
    {
      record = "homelab:power_cost_eur_month";
      expr = "homelab:host_power_watts * 730 / 1000 * ${toString kwhPriceEur}";
    }
  ];
}
