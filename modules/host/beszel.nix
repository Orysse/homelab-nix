# Beszel: a light host dashboard (CPU, memory, disk, network, temperature, SMART) with its own
# alerts, next to the VictoriaMetrics stack (spike, 2026-11-20). The hub runs on the monitoring
# host, below the cluster (D22); it only listens on localhost: reach it with
#   ssh -L 8090:127.0.0.1:8090 nuc1   then   http://localhost:8090
# The hub polls each agent over SSH: the agent holds the hub's public key (not a secret) and
# listens on loopback only. Two steps, because the hub makes its key on first start:
#   1. deploy with hubPublicKey = null (hub only), open the UI, create the admin, "Add System"
#      (host 127.0.0.1, port 45876), copy the public key it shows
#   2. paste it in hubPublicKey and deploy again: the agent starts
{ ... }:
let
  hubPublicKey = null; # "ssh-ed25519 AAAA…"
in
{
  flake.modules.nixos.beszel-hub = { ... }: {
    services.beszel.hub.enable = true;
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
