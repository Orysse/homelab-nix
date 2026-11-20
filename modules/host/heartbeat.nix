# Dead-man's switch, on the monitoring host: a ping to Healthchecks.io every minute. It emails
# when the pings stop (host down, internet down). Beszel's alerts cannot do that: they live on
# the host that would be down. The URL is a sops secret (anyone who has it can ping).
{ ... }:
{
  flake.modules.nixos.heartbeat = { config, pkgs, ... }: {
    sops.secrets.heartbeat-url = { };

    systemd.services.heartbeat = {
      description = "Ping Healthchecks.io";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        LoadCredential = "url:${config.sops.secrets.heartbeat-url.path}";
        ExecStart = pkgs.writeShellScript "heartbeat" ''
          exec ${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 10 --retry 3 \
            "$(cat "$CREDENTIALS_DIRECTORY/url")" > /dev/null
        '';
      };
    };
    systemd.timers.heartbeat = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "1min"; OnUnitActiveSec = "1min"; };
    };
  };
}
