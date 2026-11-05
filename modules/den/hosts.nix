# The topology (topology.nix) turned into den entities: one host per `hosts` entry, its k3s
# VM as a guest, and the services placed on the hosts that `services.<s>.on` names.
# The building blocks are still flake.modules.nixos.*; the aspects below only group them.
{ config, den, lib, ... }:
let
  inherit (config) cluster;
  clusterLib = import ../topology/_lib.nix { inherit lib; };
  inherit (den.lib.policy) include;
  m = config.flake.modules.nixos;

  vms = lib.filterAttrs (_: vm: vm != null)
    (lib.mapAttrs (name: _: clusterLib.k3sVmOf cluster name) cluster.hosts);
  guests = lib.mapAttrs' (_: vm: lib.nameValuePair vm.name vm) vms;
in
{
  den.hosts.x86_64-linux =
    lib.mapAttrs
      (name: _: {
        microvm.guests = lib.optional (vms ? ${name}) den.hosts.x86_64-linux.${vms.${name}.name};
      })
      cluster.hosts
    # A guest is not a flake output: it only exists inside its host.
    // lib.mapAttrs (_: _: { intoAttr = [ ]; }) guests;

  den.aspects =
    {
      homelab-host.nixos.imports = with m; [
        base boot users-ssh disk-layout network-bridge cluster-assertions k3s-token secrets
        crowdsec-bouncer
      ];
      vpn.nixos.imports = with m; [ wireguard tailscale ddns ];
      monitoring.nixos.imports = with m; [ monitoring alerting ];
      backup.nixos.imports = [ m.garage ];
      scanner.nixos.imports = [ m.trivy ];
      nfs.nixos.imports = [ m.storage ];
      postgres.nixos.imports = [ m.postgres ];
      k3s-node.nixos.imports = [ m.microvm-guest m.k3s-node ];
    }
    # The guest of each host: the k3s node, with the VM's own settings.
    // lib.mapAttrs
      (_: vm: {
        includes = [ den.aspects.k3s-node ];
        microvm = {
          autostart = true;
          # A deploy does not restart changed VMs: all at once would take the whole cluster
          # down. Restart them by hand, one at a time (`systemctl restart microvm@<node>`),
          # watching the cluster in between.
          restartIfChanged = false;
          specialArgs.vm = vm;
        };
      })
      guests;

  # Every host of the topology is a homelab host; a service aspect goes where it is placed.
  den.policies.homelab-host = { host, ... }:
    lib.optional (cluster.hosts ? ${host.name}) (include den.aspects.homelab-host);
  den.policies.service-placement = { host, ... }:
    map (s: include den.aspects.${s}) (clusterLib.servicesOn cluster host.name);
  den.schema.host.includes = [ den.policies.homelab-host den.policies.service-placement ];
}
