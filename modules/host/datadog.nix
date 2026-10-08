# L'agent du cluster est déployé par Flux ; même site et même tag cluster pour corréler.
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.datadog = { config, ... }: {
    # CONTOURNEMENT nixpkgs-unstable (2026-10) : pythonMetadataCheck cherche « checks-base »
    # au lieu de « datadog-checks-base ». À retirer quand nixpkgs#datadog-agent rebuild.
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
