# ddclient met à jour mais ne crée pas : les A <domaine> et *.<domaine> (DNS only)
# doivent exister dans la zone Cloudflare (créés le 2026-10-08).
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
      username = "token"; # valeur imposée par ddclient pour un token d'API
      passwordFile = config.sops.secrets.cloudflare-ddns-token.path;
      usev4 = "webv4, webv4=ipify-ipv4";
      usev6 = ""; # l'entrée MetalLB est IPv4 seulement
      interval = "5min";
    };
  };
}
