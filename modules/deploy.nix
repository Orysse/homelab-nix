# deploy-rs: deploys the physical hosts of the topology from this flake, each one a node.
# Magic rollback: after activation, deploy-rs must reach the host again within 30 s or the
# host reverts to its previous generation on its own (network cut, broken firewall).
#   nix run .#deploy-rs -- .          every host
#   nix run .#deploy-rs -- .#nuc1     one host
{ config, inputs, lib, ... }:
let
  inherit (config) cluster;
in
{
  flake.deploy.nodes = lib.mapAttrs (name: host: {
    hostname = host.address;
    sshUser = "root";
    profiles.system = {
      user = "root";
      path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos config.flake.nixosConfigurations.${name};
    };
  }) cluster.hosts;

  perSystem = { system, ... }: {
    packages.deploy-rs = inputs.deploy-rs.packages.${system}.deploy-rs;
    # Schema of the deploy nodes, and every host profile builds and activates.
    checks = inputs.deploy-rs.lib.${system}.deployChecks config.flake.deploy;
  };
}
