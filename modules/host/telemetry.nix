# What every host reports: its journal, pushed to VictoriaLogs on the monitoring host (no
# agent). Host metrics are Beszel's (beszel.nix).
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.telemetry = { config, lib, ... }:
    let
      clusterLib = import ../topology/_lib.nix { inherit lib; };
      monitor = clusterLib.hostAddress cluster (clusterLib.hostOf cluster "monitoring");
    in
    {
      services.journald.upload = {
        enable = true;
        settings.Upload.URL = "http://${monitor}:9428/insert/journald";
      };
    };
}
