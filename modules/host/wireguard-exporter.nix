# The WireGuard exporter, on the vpn host. Scraped by the monitoring host (monitoring.nix),
# which alone may reach it.
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.wireguard-exporter = { config, lib, pkgs, ... }:
    let
      clusterLib = import ../topology/_lib.nix { inherit lib; };
      address = clusterLib.hostAddress cluster config.networking.hostName;
      monitor = clusterLib.hostAddress cluster (clusterLib.hostOf cluster "monitoring");
      # Peers named after the topology, not their public key.
      wgNames = pkgs.writeText "wg0-names.conf" (lib.concatStrings (lib.mapAttrsToList (name: peer: ''
        [Peer]
        # friendly_name = ${name}
        PublicKey = ${peer.publicKey}
        AllowedIPs = ${peer.address}/32
      '') cluster.vpn.peers));
    in
    {
      services.prometheus.exporters.wireguard = {
        enable = true;
        listenAddress = address;
        wireguardConfig = "${wgNames}";
      };
      # It binds the host's address: wait for br0 to have it.
      systemd.services.prometheus-wireguard-exporter = {
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
      };
      networking.firewall.extraCommands =
        "iptables -A nixos-fw -p tcp -s ${monitor} --dport 9586 -j nixos-fw-accept\n";
    };
}
