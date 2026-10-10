# ddclient updates records but does not create them: the A records <domain> and
# *.<domain> (DNS only) must exist in the Cloudflare zone (created on 2026-10-08), and so
# must those of the other zones below. One token for all zones (DNS Edit on each).
{ config, ... }:
let
  inherit (config) cluster;
  # Other zones served by the same ingress (homelab-cluster: apps/holive).
  otherZones = {
    "holive.fr" = [ "holive.fr" "www.holive.fr" ];
  };
in
{
  flake.modules.nixos.ddns = { config, lib, ... }: {
    sops.secrets.cloudflare-ddns-token = { };

    services.ddclient = {
      enable = true;
      protocol = "cloudflare";
      zone = cluster.ingress.domain;
      domains = [ cluster.ingress.domain "*.${cluster.ingress.domain}" ];
      username = "token"; # value required by ddclient for an API token
      passwordFile = config.sops.secrets.cloudflare-ddns-token.path;
      usev4 = "webv4, webv4=ipify-ipv4";
      usev6 = ""; # the MetalLB entry point is IPv4 only
      interval = "5min";
      # Written before the main domains line; zone= on a host line applies to it only.
      extraConfig = lib.concatStringsSep "\n" (lib.mapAttrsToList
        (zone: hosts: "zone=${zone} ${lib.concatStringsSep "," hosts}") otherZones);
    };
  };
}
