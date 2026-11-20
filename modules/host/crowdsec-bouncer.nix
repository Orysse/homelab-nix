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
  vpnPort = cluster.vpn.port;
in
{
  flake.modules.nixos.crowdsec-bouncer = { config, lib, pkgs, ... }:
    let
      clusterLib = import ../topology/_lib.nix { inherit lib; };
      # The VPN entry points (wg0, Tailscale direct connections) stay reachable from banned
      # addresses: they are the break-glass, and a UDP port that answers only to a valid key
      # tells a scanner nothing. The bouncer runs in set-only mode: it fills the sets, and
      # these rules (ours, so the exception can be written) drop. An accept in another chain
      # would not do: a drop in any base chain of a hook is final.
      vpnPorts = "{ ${toString vpnPort}, ${toString config.services.tailscale.port} }";
      rules = pkgs.writeText "crowdsec.nft" ''
        # create then delete: a first start has nothing to delete, a restart has the old table
        table ip crowdsec
        delete table ip crowdsec
        table ip6 crowdsec6
        delete table ip6 crowdsec6

        table ip crowdsec {
          set crowdsec-blacklists { type ipv4_addr; flags timeout; }
          chain input {
            type filter hook input priority -10; policy accept;
            ip saddr @crowdsec-blacklists udp dport ${vpnPorts} accept
            ip saddr @crowdsec-blacklists drop
          }
          chain forward {
            type filter hook forward priority -10; policy accept;
            ip saddr @crowdsec-blacklists drop
          }
        }
        table ip6 crowdsec6 {
          set crowdsec6-blacklists { type ipv6_addr; flags timeout; }
          chain input {
            type filter hook input priority -10; policy accept;
            ip6 saddr @crowdsec6-blacklists udp dport ${vpnPorts} accept
            ip6 saddr @crowdsec6-blacklists drop
          }
          chain forward {
            type filter hook forward priority -10; policy accept;
            ip6 saddr @crowdsec6-blacklists drop
          }
        }
      '';
    in
    lib.mkIf (clusterLib.k3sVmOf cluster config.networking.hostName != null) {
      networking.firewall.extraCommands = "iptables -A nixos-fw -p tcp -s ${clusterLib.hostAddress cluster (clusterLib.hostOf cluster "monitoring")} --dport 60601 -j nixos-fw-accept\n";
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
        serviceConfig = {
          Restart = "on-failure";
          RestartSec = "30s";
          # "+": full privileges (the unit itself runs as a dynamic user). Before the module's
          # own pre-steps, and after the previous process stopped: no race with its cleanup.
          ExecStartPre = lib.mkBefore [ "+${lib.getExe pkgs.nftables} -f ${rules}" ];
        };
      };

      services.crowdsec-firewall-bouncer = {
        enable = true;
        createRulesets = false;   # the module would switch the whole host to networking.nftables
        secrets.apiKeyPath = config.sops.secrets.crowdsec-bouncer-key.path;
        settings = {
          mode = "nftables";
          api_url = "http://${(clusterLib.theCluster cluster).ingress.lapiAddress}:8080/";
          update_frequency = "10s";
          # set-only: the tables, sets and rules are ours (rules above); the bouncer only
          # fills the sets (crowdsec-blacklists, crowdsec6-blacklists) and empties them on stop.
          nftables = {
            ipv4 = { set-only = true; table = "crowdsec"; };
            ipv6 = { set-only = true; table = "crowdsec6"; };
          };
          nftables_hooks = [ "input" "forward" ];
          prometheus = {             # scraped by VictoriaMetrics (monitoring.nix), from the monitoring host only
            enabled = true;
            listen_addr = clusterLib.hostAddress cluster config.networking.hostName;
            listen_port = 60601;
          };
        };
      };
    };
}
