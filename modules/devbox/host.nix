# The devbox VM as seen from its host: the directories its virtiofs shares point to, plus
# the eval check that pins the guest's shape. The guest itself: guest.nix.
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.devbox-host = { config, lib, ... }:
    let
      clusterLib = import ../topology/_lib.nix { inherit lib; };
      devboxes = lib.attrNames (clusterLib.devboxesOn cluster config.networking.hostName);
    in
    {
      systemd.tmpfiles.settings = lib.mkMerge (map
        (n: {
          # Volume images without btrfs copy-on-write, as for the kube nodes (k3s/token.nix);
          # +C only applies to files created afterwards, so the directory comes first.
          "20-devbox-${n}-vm" = {
            "/var/lib/microvms/${n}" = {
              d = { mode = "0755"; user = "root"; group = "root"; };
              h.argument = "+C";
            };
            "/var/lib/microvms/${n}/persist".d = { mode = "0755"; user = "root"; group = "root"; };
          };
          # State that survives a rebuild: home (uid 1000 = abel in the guest) and the
          # Tailscale node identity (only root may read it).
          "20-devbox-${n}-data" = {
            "/srv/data/${n}".d = { mode = "0755"; user = "root"; group = "root"; };
            "/srv/data/${n}/home".d = { mode = "0700"; user = "1000"; group = "1000"; };
            "/srv/data/${n}/tailscale".d = { mode = "0700"; user = "root"; group = "root"; };
          };
        })
        devboxes);
    };

  # Eval-only check on nuc1's guest `devbox`: RAM, persisted shares, user and the limits
  # that keep the box from taking the host down (cf. 2026-10-11).
  perSystem = { lib, pkgs, ... }: {
    checks.devbox-vm-shape =
      let
        guest = config.flake.nixosConfigurations.nuc1.config.microvm.vms.devbox.config.config;
        shares = lib.listToAttrs (map (s: lib.nameValuePair s.tag s) guest.microvm.shares);
      in
      assert guest.microvm.mem == 2500;
      assert guest.microvm.balloon;
      assert shares.home.source == "/srv/data/devbox/home";
      assert shares.home.mountPoint == "/home/abel";
      assert shares.tailscale.source == "/srv/data/devbox/tailscale";
      assert shares.tailscale.mountPoint == "/var/lib/tailscale";
      assert guest.users.users.abel.uid == 1000;
      assert guest.boot.kernel.sysctl."vm.swappiness" == 10;
      assert guest.systemd.slices."user-1000".sliceConfig.MemoryMax == "2G";
      pkgs.runCommand "devbox-vm-shape" { } "touch $out";
  };
}
