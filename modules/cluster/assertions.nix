{ config, lib, ... }:
let
  clusterLib = import ./_lib.nix { inherit lib; };
  inherit (config) cluster;
in
{
  # Brique importée par chaque host : la topologie invalide fait échouer le build.
  flake.modules.nixos.cluster-assertions = {
    assertions = map (message: { assertion = false; inherit message; }) (clusterLib.validate cluster);
  };

  # Test négatif : une topologie avec IP dupliquée doit être rejetée.
  perSystem = { pkgs, ... }: {
    checks.topology-rejects-duplicate-ip =
      let
        # La vraie topologie, puis la même avec une IP en double.
        good = cluster;
        bad = lib.recursiveUpdate good { nodes.kube-2.address = "192.168.1.211"; };
        errors = clusterLib.validate bad;
      in
      assert clusterLib.validate good == [ ];
      assert lib.any (lib.hasPrefix "IP dupliquées") errors;
      assert clusterLib.validate cluster == [ ];
      pkgs.runCommand "topology-rejects-duplicate-ip" { } ''
        echo ${lib.escapeShellArg (toString errors)} > $out
      '';
  };
}
