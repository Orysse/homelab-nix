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
        bad = lib.recursiveUpdate good { hosts.nuc1.address = "192.168.1.210"; };
        errors = clusterLib.validate bad;
      in
      assert clusterLib.validate good == [ ];
      assert lib.any (lib.hasPrefix "duplicate IPs") errors;
      assert clusterLib.validate cluster == [ ];
      pkgs.runCommand "topology-rejects-duplicate-ip" { } ''
        echo ${lib.escapeShellArg (toString errors)} > $out
      '';

    # Negative test: a node's local volume must hold at least one database.
    checks.topology-rejects-small-local-disk =
      let
        errors = clusterLib.validate (lib.recursiveUpdate cluster { nodes.kube-0.localDisk = 1024; });
      in
      assert lib.any (lib.hasPrefix "localDisk below 4096 MiB") errors;
      pkgs.runCommand "topology-rejects-small-local-disk" { } ''
        echo ${lib.escapeShellArg (toString errors)} > $out
      '';

    # Negative test: backups must go to a host that exists.
    checks.topology-rejects-unknown-backup-host =
      let
        errors = clusterLib.validate (lib.recursiveUpdate cluster { backup.host = "nas"; });
      in
      assert lib.any (lib.hasPrefix "backup.host refers to an unknown host") errors;
      pkgs.runCommand "topology-rejects-unknown-backup-host" { } ''
        echo ${lib.escapeShellArg (toString errors)} > $out
      '';
  };
}
