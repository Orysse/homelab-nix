# Unit tests of the power recording rules (_power-rules.nix), with fixed input series:
# vmalert-tool evaluates them the way vmalert on the monitoring host will.
{
  perSystem = { pkgs, ... }:
    let
      rules = pkgs.writeText "power-rules.yaml"
        (builtins.toJSON { groups = [ (import ./_power-rules.nix) ]; });
      tests = pkgs.writeText "power-rules-test.yaml" (builtins.toJSON {
        rule_files = [ "power-rules.yaml" ];
        evaluation_interval = "1m";
        tests = [{
          interval = "1m";
          input_series = [
            # nuc1: 10 W from RAPL (600 J a minute), one busy core.
            { series = ''node_rapl_package_joules_total{job="node",host="nuc1"}''; values = "0+600x20"; }
            { series = ''node_cpu_seconds_total{job="node",host="nuc1",cpu="0",mode="user"}''; values = "0+60x20"; }
            { series = ''node_cpu_seconds_total{job="node",host="nuc1",cpu="0",mode="idle"}''; values = "0+0x20"; }
            # kube-0 uses half a core of it; the namespace gatus a quarter of that.
            { series = ''node_cpu_seconds_total{job="prometheus-node-exporter",node="kube-0",cpu="0",mode="user"}''; values = "0+30x20"; }
            { series = ''container_cpu_usage_seconds_total{job="cadvisor",instance="kube-0",namespace="gatus",container="gatus"}''; values = "0+7.5x20"; }
          ];
          metricsql_expr_test = [
            { expr = "homelab:host_power_watts"; eval_time = "10m";
              exp_samples = [{ labels = ''homelab:host_power_watts{host="nuc1"}''; value = 15; }]; }
            { expr = "homelab:vm_power_watts"; eval_time = "10m";
              exp_samples = [{ labels = ''homelab:vm_power_watts{node="kube-0"}''; value = 5; }]; }
            { expr = "homelab:namespace_power_watts"; eval_time = "10m";
              exp_samples = [{ labels = ''homelab:namespace_power_watts{node="kube-0",namespace="gatus"}''; value = 1.25; }]; }
            { expr = "homelab:power_cost_eur_month"; eval_time = "10m";
              exp_samples = [{ labels = ''homelab:power_cost_eur_month{host="nuc1"}''; value = 2.7375; }]; }
          ];
        }];
      });
    in
    {
      checks.power-rules = pkgs.runCommand "power-rules" { nativeBuildInputs = [ pkgs.victoriametrics ]; } ''
        cp ${rules} power-rules.yaml
        cp ${tests} power-rules-test.yaml
        vmalert-tool unittest --files power-rules-test.yaml
        touch $out
      '';
    };
}
