# Serveur WireGuard d'administration (wg0), sur le host désigné par cluster.vpn.host.
# Indépendant de k3s : l'accès d'admin marche même si le cluster est en panne.
# Clé privée : secret sops wireguard-private-key. Clients : cluster.vpn.peers (topologie).
# Le trafic sortant du tunnel vers le LAN est NATé avec l'IP du host : les machines du
# homelab lui répondent sans route de retour à configurer.
{ config, ... }:
let
  inherit (config) cluster;
  vpn = cluster.vpn;
in
{
  flake.modules.nixos.wireguard = { config, lib, pkgs, ... }: {
    sops.secrets.wireguard-private-key.owner = "systemd-network";
    environment.systemPackages = [ pkgs.wireguard-tools ]; # `wg show` pour diagnostiquer

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

    networking.nat = {
      enable = true;
      internalInterfaces = [ "wg0" ];
      externalInterface = "br0";
    };
  };
}
