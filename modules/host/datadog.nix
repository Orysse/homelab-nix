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
