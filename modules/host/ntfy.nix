# ntfy: push notifications to the phone, on the monitoring host like Alertmanager, so alerts
# still arrive when the cluster is down (D22). Alertmanager posts to topic "homelab"
# (alerting.nix); the phone app subscribes to it.
#   public  https://ntfy.<domain>:8443, router TCP forward 8443 -> this host; certificate from
#           Let's Encrypt by DNS-01 (the ddclient token can edit the zone)
#   local   http://127.0.0.1:2586 (Alertmanager)
#   iOS     instant delivery goes through ntfy.sh (upstream-base-url): it relays a "poll now"
#           signal, never the message itself
# Access: nobody by default. User "abel" (admin, phone app and web login, password hash in
# sops: `nix run nixpkgs#ntfy-sh -- user hash`) and its token for Alertmanager (sops).
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.ntfy = { config, lib, ... }:
    let
      domain = cluster.ingress.domain;
      name = "ntfy.${domain}";
      port = 8443;
      creds = "/run/credentials/ntfy-sh.service";
    in
    lib.mkIf (cluster.monitoring.host == config.networking.hostName) {
      sops.secrets.ntfy-admin-hash = { };
      sops.secrets.ntfy-alertmanager-token = { };
      # Declarative users and tokens (ntfy re-applies them at every start).
      sops.templates."ntfy.env".content = ''
        NTFY_AUTH_USERS=abel:${config.sops.placeholder.ntfy-admin-hash}:admin
        NTFY_AUTH_TOKENS=abel:${config.sops.placeholder.ntfy-alertmanager-token}:alertmanager
      '';

      security.acme = {
        acceptTerms = true;
        certs.${name} = {
          dnsProvider = "cloudflare";
          credentialFiles.CF_DNS_API_TOKEN_FILE = config.sops.secrets.cloudflare-ddns-token.path;
          reloadServices = [ "ntfy-sh.service" ];
        };
      };

      services.ntfy-sh = {
        enable = true;
        environmentFile = config.sops.templates."ntfy.env".path;
        settings = {
          base-url = "https://${name}:${toString port}";
          listen-https = ":${toString port}";
          listen-http = "127.0.0.1:2586";
          cert-file = "${creds}/cert.pem";
          key-file = "${creds}/key.pem";
          auth-default-access = "deny-all";
          enable-login = true;
          enable-signup = false;
          upstream-base-url = "https://ntfy.sh";
          cache-duration = "72h";
          attachment-total-size-limit = "0";   # no attachments
          enable-metrics = true;
          metrics-listen-http = "127.0.0.1:9095";
        };
      };
      # DynamicUser: systemd hands it copies of the root-only certificate files.
      systemd.services.ntfy-sh = {
        # acme-<name> puts a certificate in place (self-signed until the real one is issued);
        # the order itself runs after ntfy is up, then reloads it.
        wants = [ "acme-${name}.service" ];
        after = [ "acme-${name}.service" ];
        before = [ "acme-order-renew-${name}.service" ];
        serviceConfig.LoadCredential = [
          "cert.pem:/var/lib/acme/${name}/fullchain.pem"
          "key.pem:/var/lib/acme/${name}/key.pem"
        ];
      };
      networking.firewall.allowedTCPPorts = [ port ];
    };
}
