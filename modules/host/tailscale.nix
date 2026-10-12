# Tailscale: this host is the tailnet's subnet router for vpn.routes (homelab only, not the
# whole LAN), and an exit node: an admin away from home can send all their traffic through
# it (`tailscale set --exit-node=nuc1`; the Headscale policy lets only admins use it).
# The control server, Headscale, runs in the cluster (homelab-cluster: apps/headscale,
# https://hs.<domain>); the routes themselves do not depend on the cluster.
# wg0 (wireguard.nix) stays as break-glass for the admin's laptop: it needs neither the
# cluster nor Pocket-ID.
# Router port forwarding: UDP 41641 -> this host (direct connections; DERP relays otherwise).
# One-time setup (state in /var/lib/tailscale):
#   kubectl -n headscale exec deploy/headscale -- headscale users create infra
#   kubectl -n headscale exec deploy/headscale -- headscale preauthkeys create --user <infra id> --expiration 1h
#   tailscale up --login-server https://hs.<domain> --auth-key <key>   (here)
#   kubectl -n headscale exec deploy/headscale -- headscale nodes approve-routes --identifier <id> --routes <vpn.routes>,0.0.0.0/0,::/0
{ config, ... }:
let
  vpn = config.cluster.vpn;
in
{
  flake.modules.nixos.tailscale = { lib, ... }: {
    services.tailscale = {
      enable = true;
      useRoutingFeatures = "server";    # IP forwarding, loose reverse-path filter
      openFirewall = true;              # UDP 41641, direct connections
      extraSetFlags = [
        "--advertise-routes=${lib.concatStringsSep "," vpn.routes}"
        "--advertise-exit-node"
        "--accept-dns=false"
      ];
    };
  };
}
