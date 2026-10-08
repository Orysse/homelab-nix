# ddclient updates records but does not create them: the A records <domain> and
# *.<domain> (DNS only) must exist in the Cloudflare zone (created on 2026-10-08).
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.ddns = { config, ... }: {
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
    };
  };
}
