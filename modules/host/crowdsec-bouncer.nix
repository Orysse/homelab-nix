# CrowdSec's bans, enforced by the kernel of every host that runs cluster nodes. CrowdSec
# itself (detection, decisions) runs in the cluster and reads the Gateways' access log;
# CrowdSec's own firewall bouncer, here, pulls the decisions from its LAPI
# (topology ingress.lapiAddress) into nftables sets and drops those addresses (ADR 0003 in
# homelab-cluster).
#   input    traffic to the host itself
#   forward  traffic bridged to the VMs (br0): the Gateways' addresses live there. Bridged
#            frames reach the IP hooks only with br_netfilter.
# The decisions carry their own expiry: if the LAPI is unreachable, bans stay until then.
# Temporary place: a firewall VM in front of the cluster takes it over with the NUC7s.
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.crowdsec-bouncer = { config, lib, ... }:
    let
      clusterLib = import ../topology/_lib.nix { inherit lib; };
    in
    lib.mkIf (clusterLib.k3sVmOf cluster config.networking.hostName != null) {
      boot.kernelModules = [ "br_netfilter" ];
      boot.kernel.sysctl = {
        "net.bridge.bridge-nf-call-iptables" = 1;
        "net.bridge.bridge-nf-call-ip6tables" = 1;
      };

      # The same key is in OpenBao (kv/apps/crowdsec/bouncer), where the LAPI reads it to
      # register this bouncer.
      sops.secrets.crowdsec-bouncer-key = { };

      # Until the cluster (and so the LAPI) is up the bouncer cannot start: keep trying.
      systemd.services.crowdsec-firewall-bouncer = {
        unitConfig.StartLimitIntervalSec = 0;
        serviceConfig = { Restart = "on-failure"; RestartSec = "30s"; };
      };

      services.crowdsec-firewall-bouncer = {
        enable = true;
        createRulesets = false;   # the module would switch the whole host to networking.nftables
        secrets.apiKeyPath = config.sops.secrets.crowdsec-bouncer-key.path;
        settings = {
          mode = "nftables";
          api_url = "http://${(clusterLib.theCluster cluster).ingress.lapiAddress}:8080/";
          update_frequency = "10s";
          # The bouncer creates and owns its tables (crowdsec, crowdsec6) and their chains.
          nftables = {
            ipv4.set-only = false;
            ipv6.set-only = false;
          };
          nftables_hooks = [ "input" "forward" ];
          prometheus = {             # scraped by VictoriaMetrics (monitoring.nix)
            enabled = true;
            listen_addr = "127.0.0.1";
            listen_port = 60601;
          };
        };
      };
    };
}
