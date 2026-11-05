# The gate subset of the den port (phase 2a): host nuc1, aspect homelab-host (base.nix),
# one service (backup = garage.nix) placed by a policy, and the k3s guest kube-0.
# Everything else still comes from flake.modules.nixos.* (see modules/machines/nuc1.nix).
{ config, den, lib, ... }:
let
  inherit (config) cluster;
  inherit (den.lib.policy) include;
  m = config.flake.modules.nixos;
in
{
  den.hosts.x86_64-linux = {
    nuc1.microvm.guests = [ den.hosts.x86_64-linux.kube-0 ];
    # A guest is not a flake output: it only exists inside its host.
    kube-0.intoAttr = [ ];
  };

  den.aspects.homelab-host.nixos.imports = [ m.base ];
  den.aspects.backup.nixos.imports = [ m.garage ];
  den.aspects.k3s-node.nixos.imports = [ m.microvm-guest m.k3s-node ];

  den.aspects.kube-0 = {
    includes = [ den.aspects.k3s-node ];
    microvm = {
      autostart = true;
      # A deploy does not restart changed VMs: all at once would take the whole cluster
      # down. Restart them by hand, one at a time (`systemctl restart microvm@<node>`),
      # watching the cluster in between.
      restartIfChanged = false;
      specialArgs.node = "kube-0";
    };
  };

  # Placement: the backup service runs on the host named by the topology.
  den.policies.backup-placement = { host, ... }:
    lib.optional (host.name == cluster.backup.host) (include den.aspects.backup);
  den.schema.host.includes = [ den.policies.backup-placement ];
}
