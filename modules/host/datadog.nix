# The cluster agent is deployed by Flux; same site and cluster tag so both correlate.
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.datadog = { config, ... }: {
    systemd.tmpfiles.rules = [
      "d /var/lib/datadog-agent/run 0750 datadog datadog -"
      "d /run/datadog 0755 datadog datadog -"
    ];

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
      tags = [ "cluster:${cluster.name}" "env:homelab" "role:hypervisor" ];
      enableLiveProcessCollection = true;
      # Packaging paths (/opt/datadog-agent/run, /var/run/datadog) do not exist on NixOS.
      extraConfig = {
        run_path = "/var/lib/datadog-agent/run";
        dogstatsd_socket = "/run/datadog/dsd.socket";
      };
      # The module's default sets use_mount = "false" (a string): the Go disk check rejects
      # it and the agent logs an error before falling back to the Python check.
      diskCheck = {
        init_config = { };
        instances = [{
          use_mount = false;
          file_system_exclude = [ "tmpfs" "devtmpfs" "ramfs" "overlay" "efivarfs" ];
        }];
      };
    };
  };
}
