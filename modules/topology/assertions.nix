{ config, lib, ... }:
let
  clusterLib = import ./_lib.nix { inherit lib; };
  inherit (config) cluster;
in
{
  flake.modules.nixos.cluster-assertions = {
    assertions = map (message: { assertion = false; inherit message; }) (clusterLib.validate cluster);
  };

  # Negative test: a duplicate IP must be rejected.
  perSystem = { pkgs, ... }: {
    checks.topology-rejects-duplicate-ip =
      let
        good = cluster;
        bad = lib.recursiveUpdate good { nodes.kube-2.address = "192.168.1.211"; };
        errors = clusterLib.validate bad;
      in
      assert clusterLib.validate good == [ ];
      assert lib.any (lib.hasPrefix "duplicate IPs") errors;
      assert clusterLib.validate cluster == [ ];
      pkgs.runCommand "topology-rejects-duplicate-ip" { } ''
        echo ${lib.escapeShellArg (toString errors)} > $out
      '';
  };
}
