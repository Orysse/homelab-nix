{ config, lib, ... }:
let
  clusterLib = import ./_lib.nix { inherit lib; };
  inherit (config) cluster;
  second = { id = 1; ram = 16384; cores = 4; dataDisk = 32768; localDisk = 20480; };
in
{
  flake.modules.nixos.cluster-assertions = {
    assertions = map (message: { assertion = false; inherit message; }) (clusterLib.validate cluster);
  };

  # Negative tests: each bad topology must be rejected with the expected message.
  perSystem = { pkgs, ... }:
    let
      reject = name: patch: prefix:
        let errors = clusterLib.validate (lib.recursiveUpdate cluster patch);
        in
        assert lib.any (lib.hasPrefix prefix) errors;
        pkgs.runCommand "topology-rejects-${name}" { } ''
          echo ${lib.escapeShellArg (toString errors)} > $out
        '';
      extraVm = address: { vms.test = { on = "nuc1"; mem = 512; inherit address; }; };
    in
    {
      checks = {
        topology-accepts-current =
          assert clusterLib.validate cluster == [ ];
          pkgs.runCommand "topology-accepts-current" { } "touch $out";

        topology-rejects-duplicate-ip = reject "duplicate-ip" (extraVm "192.168.1.200") "duplicate IPs";
        topology-rejects-small-local-disk = reject "small-local-disk" { hosts.nuc1.localDisk = 1024; } "localDisk below 4096 MiB";
        topology-rejects-unknown-service-host = reject "unknown-service-host" { services.backup.on = "nas"; } "services.backup.on refers to an unknown host";
        topology-rejects-two-servers = reject "two-servers" {
          hosts.nuc2 = second;
          clusters.homelab.servers = [ "nuc1" "nuc2" ];
        } "cluster homelab: an odd number of servers";
        topology-rejects-host-in-two-clusters = reject "host-in-two-clusters" {
          clusters.other = { servers = [ "nuc1" ]; agents = [ ]; gitops.url = "x"; oidc = { issuer = "x"; audiences = [ ]; }; ingress = { address = "x"; lapiAddress = "x"; internalAddress = "x"; pool = "x"; domain = "x"; }; };
        } "host in two clusters";
        topology-rejects-host-id-out-of-range = reject "host-id-out-of-range" { hosts.nuc1.id = 12; } "host id out of range";
        topology-rejects-memory-under-floor = reject "memory-under-floor" { hosts.nuc1.ram = 12288; } "k3s VM kube-0 would get";
        topology-rejects-vm-in-dhcp-range = reject "vm-in-dhcp-range" (extraVm "192.168.1.100") "vms.test.address is in the DHCP range";
        topology-rejects-vm-in-lb-pool = reject "vm-in-lb-pool" (extraVm "192.168.1.245") "vms.test.address is in the LoadBalancer pool";
        topology-rejects-vm-in-k3s-range = reject "vm-in-k3s-range" (extraVm "192.168.1.215") "vms.test.address is in the k3s VM range";

        # The derived size is the one the owner approved, and never exactly 2048.
        topology-derives-approved-memory =
          assert clusterLib.vmMem cluster "nuc1" == 9216;
          assert clusterLib.vmMem (lib.recursiveUpdate cluster { hosts.nuc1.ram = 2048 + 7168; }) "nuc1" != 2048;
          pkgs.runCommand "topology-derives-approved-memory" { } "touch $out";
      };
    };
}
