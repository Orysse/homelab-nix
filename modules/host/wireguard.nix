# On the host rather than in k3s: admin access must survive a cluster outage.
# NAT to br0: the LAN replies to the host, no return route to configure.
{ config, ... }:
let
  inherit (config) cluster;
  vpn = cluster.vpn;
in
{
  flake.modules.nixos.wireguard = { config, lib, pkgs, ... }: {
    sops.secrets.wireguard-private-key.owner = "systemd-network";
    environment.systemPackages = [ pkgs.wireguard-tools ];

    systemd.network.netdevs."50-wg0" = {
      netdevConfig = { Kind = "wireguard"; Name = "wg0"; };
      wireguardConfig = {
        PrivateKeyFile = config.sops.secrets.wireguard-private-key.path;
        ListenPort = vpn.port;
      };
      wireguardPeers = lib.mapAttrsToList (_: peer: {
        PublicKey = peer.publicKey;
        AllowedIPs = [ "${peer.address}/32" ];
      }) vpn.peers;
    };

    systemd.network.networks."50-wg0" = {
      matchConfig.Name = "wg0";
      address = [ "${vpn.serverAddress}/${toString vpn.prefixLength}" ];
    };

    networking.firewall.allowedUDPPorts = [ vpn.port ];

    # Clients only reach the homelab (vpn.routes), not the rest of the LAN: the routes
    # pushed to clients are only a client-side setting.
    networking.firewall.extraCommands = ''
      iptables -D FORWARD -i wg0 -j homelab-vpn-fwd 2>/dev/null || true
      iptables -F homelab-vpn-fwd 2>/dev/null || iptables -N homelab-vpn-fwd
      ${lib.concatMapStrings (net: "iptables -A homelab-vpn-fwd -d ${net} -j RETURN\n") vpn.routes}
      iptables -A homelab-vpn-fwd -j REJECT --reject-with icmp-admin-prohibited
      iptables -I FORWARD -i wg0 -j homelab-vpn-fwd
    '';
    networking.firewall.extraStopCommands = ''
      iptables -D FORWARD -i wg0 -j homelab-vpn-fwd 2>/dev/null || true
      iptables -F homelab-vpn-fwd 2>/dev/null || true
      iptables -X homelab-vpn-fwd 2>/dev/null || true
    '';

    networking.nat = {
      enable = true;
      internalInterfaces = [ "wg0" ];
      externalInterface = "br0";
    };
  };
}
