# Agent Datadog sur le host physique : CPU, RAM, disques, réseau, processus (dont les
# QEMU des microVMs). Le cluster a son propre agent, déployé par Flux (homelab-cluster).
# Même site et même tag de cluster que lui (topologie), pour corréler host et cluster.
# Clé d'API : secret sops datadog-api-key.
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.datadog = { config, ... }: {
    # CONTOURNEMENT nixpkgs-unstable (2026-10) : le contrôle de métadonnées Python cherche
    # « checks-base » au lieu de « datadog-checks-base » et casse le build des intégrations.
    # À retirer quand `nix build nixpkgs#datadog-agent` repasse.
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
