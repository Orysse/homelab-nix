# WireGuard peers -> Datadog, on the VPN host: handshake age, connected, bytes per peer,
# sent to the local DogStatsD every minute. Peers are tagged with their topology name, not
# their public key. No Python integration needed.
{ config, lib, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.datadog = { config, pkgs, ... }:
    let
      peerNames = lib.concatStringsSep " " (lib.mapAttrsToList
        (name: peer: "[${lib.escapeShellArg peer.publicKey}]=${lib.escapeShellArg name}")
        cluster.vpn.peers);
    in
    lib.mkIf (cluster.vpn.host == config.networking.hostName) {
      systemd.services.datadog-wireguard = {
        description = "Send WireGuard peer metrics to DogStatsD";
        after = [ "datadog-agent.service" ];
        path = [ pkgs.wireguard-tools ];
        serviceConfig.Type = "oneshot";
        script = ''
          declare -A names=(${peerNames})
          now=$(date +%s)
          send() { echo "$1" > /dev/udp/127.0.0.1/8125; }
          wg show wg0 dump | tail -n +2 | while IFS=$'\t' read -r pub _ _ _ handshake rx tx _; do
            tags="#interface:wg0,peer:''${names[$pub]:-unknown}"
            connected=0
            if [ "$handshake" -gt 0 ]; then
              age=$((now - handshake))
              send "homelab.wireguard.peer.handshake_age:$age|g|$tags"
              [ "$age" -lt 180 ] && connected=1   # WireGuard re-handshakes every 2 min when active
            fi
            send "homelab.wireguard.peer.connected:$connected|g|$tags"
            send "homelab.wireguard.peer.rx_bytes:$rx|g|$tags"
            send "homelab.wireguard.peer.tx_bytes:$tx|g|$tags"
          done
        '';
      };
      systemd.timers.datadog-wireguard = {
        wantedBy = [ "timers.target" ];
        timerConfig = { OnBootSec = "1min"; OnUnitActiveSec = "1min"; };
      };
    };
}
