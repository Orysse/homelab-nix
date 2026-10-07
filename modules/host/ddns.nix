# DNS dynamique : tient l'enregistrement A du domaine à jour avec l'IP publique de la
# box (zone chez Cloudflare). Le NUC sort par la box : l'IP vue de l'extérieur est la sienne.
# Token : API Cloudflare limité à la zone, droit « DNS Edit » (secret sops cloudflare-ddns-token).
# ddclient MET À JOUR mais ne CRÉE pas : les enregistrements A <domaine> et *.<domaine>
# (DNS only, nuage gris) doivent exister dans la zone (créés une fois, le 2026-10-08).
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
      username = "token"; # convention ddclient pour un token d'API Cloudflare
      passwordFile = config.sops.secrets.cloudflare-ddns-token.path;
      usev4 = "webv4, webv4=ipify-ipv4";
      usev6 = ""; # pas d'AAAA : l'entrée du cluster (MetalLB) est en IPv4
      interval = "5min";
    };
  };
}
