# The cluster agent is deployed by Flux; same site and cluster tag so both correlate.
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.datadog = { config, ... }: {
    # WORKAROUND nixpkgs-unstable (2026-10): pythonMetadataCheck looks for "checks-base"
    # instead of "datadog-checks-base". Remove once nixpkgs#datadog-agent builds again.
    nixpkgs.overlays = [
      (final: prev: {
        datadog-integrations-core = extras:
          prev.callPackage "${prev.path}/pkgs/tools/networking/dd-agent/integrations-core.nix" {
            extraIntegrations = extras;
            python3Packages = prev.python3Packages // {
              buildPythonPackage = args:
                prev.python3Packages.buildPythonPackage (args // { dontCheckPythonMetadata = true; });
            };
          };
      })
    ];

    sops.secrets.datadog-api-key.owner = "datadog";

    services.datadog-agent = {
      enable = true;
      site = cluster.datadog.site;
      apiKeyFile = config.sops.secrets.datadog-api-key.path;
      hostname = config.networking.hostName;
      tags = [ "cluster:${cluster.name}" "role:hypervisor" ];
      enableLiveProcessCollection = true;
    };
  };
}
