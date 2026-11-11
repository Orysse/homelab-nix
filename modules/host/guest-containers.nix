# LAN guests with isolation = "container" (topology `guests`): one systemd-nspawn container
# each, on br0 with its own address and firewall, so the wide ports a guest needs are open in
# it only (docs/specs/2026-11-11-lan-guests.md). Its state: /var/lib/nixos-containers/<name>.
# shortcut: the guest's journal stays in the container (journalctl -M <name>), not in
# VictoriaLogs; ship it (and add the guest's IP to monitoring.nix's 9428 rule) if it matters.
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.guest-containers = { config, lib, ... }:
    let
      clusterLib = import ../topology/_lib.nix { inherit lib; };
      guests = lib.filterAttrs (_: g: g.isolation == "container")
        (clusterLib.guestsOn cluster config.networking.hostName);
      hostStateVersion = config.system.stateVersion;
    in
    {
      containers = lib.mapAttrs
        (_: g: {
          autoStart = true;
          privateNetwork = true;
          hostBridge = "br0";
          localAddress = "${g.address}/${toString cluster.network.prefixLength}";
          privateUsers = "pick";   # the container's root is not the host's
          config = {
            imports = [ g.module ];
            networking.defaultGateway = cluster.network.gateway;
            networking.nameservers = cluster.network.dns;
            # The host's resolver (resolved, 127.0.0.53) is out of reach from another netns.
            networking.useHostResolvConf = lib.mkForce false;
            # mDNS answers (multicast) are not tracked connections: open, as on the host and kube-0.
            networking.firewall.allowedUDPPorts = [ 5353 ];
            system.stateVersion = hostStateVersion;
          };
        })
        guests;

      systemd.services = lib.mapAttrs'
        (name: g: lib.nameValuePair "container@${name}" {
          serviceConfig.MemoryMax = "${toString g.mem}M";
        })
        guests;
    };
}
