# Beszel: a light host dashboard (CPU, memory, disk, network, temperature) with its own
# alerts, in place of the VictoriaMetrics stack (D35). The hub runs on the monitoring host,
# below the cluster (D22), and listens on the host's address: the internal Gateway reaches it
# at https://beszel.int.<domain> (homelab-cluster apps/beszel). Login is Pocket-ID, through an
# oauth2-proxy there: the route stamps the admin's email in X-Beszel-Email, and the hub trusts
# that header only from the k3s VMs (TRUSTED_PROXY_IPS), the only addresses the firewall lets in.
# The hub polls each agent over SSH: the agent holds the hub's public key (not a secret) and
# listens on loopback only. Two steps, because the hub makes its key on first start:
#   1. deploy with hubPublicKey = null (hub only), open the UI, create the admin, "Add System"
#      (host 127.0.0.1, port 45876), copy the public key it shows
#   2. paste it in hubPublicKey and deploy again: the agent starts
{ config, ... }:
let
  inherit (config) cluster;
  hubPublicKey = null; # "ssh-ed25519 AAAA…"
in
{
  flake.modules.nixos.beszel-hub = { config, lib, ... }:
    let
      clusterLib = import ../topology/_lib.nix { inherit lib; };
      domain = (clusterLib.theCluster cluster).ingress.domain;
    in
    {
      services.beszel.hub = {
        enable = true;
        host = clusterLib.hostAddress cluster config.networking.hostName;
        environment = {
          APP_URL = "https://beszel.int.${domain}";
          TRUSTED_AUTH_HEADER = "X-Beszel-Email";
          TRUSTED_PROXY_IPS = lib.concatStringsSep "," (clusterLib.vmIPs cluster);
        };
      };
      networking.firewall.extraCommands = lib.concatMapStrings
        (ip: "iptables -A nixos-fw -p tcp -s ${ip} --dport 8090 -j nixos-fw-accept\n")
        (clusterLib.vmIPs cluster);
    };

  flake.modules.nixos.beszel-agent = { lib, ... }: {
    services.beszel.agent = lib.mkIf (hubPublicKey != null) {
      enable = true;
      environment = {
        KEY = hubPublicKey;
        LISTEN = "127.0.0.1:45876";
      };
    };
  };
}
