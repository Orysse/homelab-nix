# Headscale: self-hosted Tailscale control server, the everyday VPN. On the host, like wg0:
# it must survive a cluster outage. wg0 (wireguard.nix) stays as break-glass for the admin's
# laptop: it needs neither the cluster nor Pocket-ID.
#   control  https://<vpn.headscale.name>:<port>, router TCP forward to this host; certificate
#            from Let's Encrypt by DNS-01 (the ddclient token can edit the zone)
#   login    Pocket-ID, group "admins" only (the issuer runs in the cluster: when it is down,
#            logged-in devices keep working until their key expires, 180 days; new logins
#            wait, or use a pre-auth key created here)
#   relays   Tailscale's public DERP servers (traffic stays end-to-end WireGuard-encrypted)
#   routes   this host is the subnet router for vpn.routes (homelab only, not the whole LAN)
# One-time setup (state in /var/lib/headscale and /var/lib/tailscale), see docs/cheatsheet.md:
#   headscale users create infra
#   headscale preauthkeys create --user <infra id> --expiration 1h
#   tailscale up --login-server <url> --auth-key <key>       (then routes are advertised)
#   headscale nodes approve-routes --identifier <id> --routes <vpn.routes>
{ config, ... }:
let
  inherit (config) cluster;
  vpn = cluster.vpn;
  hs = vpn.headscale;
  url = "https://${hs.name}:${toString hs.port}";
in
{
  flake.modules.nixos.headscale = { config, lib, pkgs, ... }: {
    sops.secrets.headscale-oidc-secret.owner = "headscale";

    security.acme = {
      acceptTerms = true;
      certs.${hs.name} = {
        dnsProvider = "cloudflare";
        # The ddclient token (DNS Edit on the zone), read through LoadCredential.
        credentialFiles.CF_DNS_API_TOKEN_FILE = config.sops.secrets.cloudflare-ddns-token.path;
        group = "headscale";
        reloadServices = [ "headscale.service" ];
      };
    };

    services.headscale = {
      enable = true;
      address = "0.0.0.0";
      port = hs.port;
      settings = {
        server_url = url;
        tls_cert_path = "/var/lib/acme/${hs.name}/fullchain.pem";
        tls_key_path = "/var/lib/acme/${hs.name}/key.pem";
        dns = {
          magic_dns = true;
          base_domain = hs.baseDomain;
          override_local_dns = false;   # clients keep their own DNS
        };
        oidc = {
          issuer = cluster.oidc.issuer;
          client_id = hs.oidcClientId;
          client_secret_path = config.sops.secrets.headscale-oidc-secret.path;
          scope = [ "openid" "profile" "email" "groups" ];
          allowed_groups = [ "admins" ];
          pkce.enabled = true;
        };
        # Only the homelab networks, like wg0. Every user who can log in is an admin for now;
        # friends with restricted access get their own group here later.
        policy.path = pkgs.writeText "headscale-policy.json" (builtins.toJSON {
          acls = [{
            action = "accept";
            src = [ "*" ];
            dst = map (net: "${net}:*") vpn.routes;
          }];
        });
      };
    };
    systemd.services.headscale = {
      wants = [ "acme-finished-${hs.name}.target" ];
      after = [ "acme-finished-${hs.name}.target" ];
    };
    networking.firewall.allowedTCPPorts = [ hs.port ];
    environment.systemPackages = [ config.services.headscale.package ];

    # This host joins its own tailnet as the subnet router.
    services.tailscale = {
      enable = true;
      useRoutingFeatures = "server";    # IP forwarding, loose reverse-path filter
      openFirewall = true;              # UDP 41641, direct connections
      extraSetFlags = [
        "--advertise-routes=${lib.concatStringsSep "," vpn.routes}"
        "--accept-dns=false"
      ];
    };
  };
}
