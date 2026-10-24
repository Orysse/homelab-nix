# `node` (specialArgs): the VM's name in the topology (a node or a devbox).
{ config, ... }:
let
  inherit (config) cluster;
  topModules = config.flake.modules.nixos;
in
{
  flake.modules.nixos.microvm-guest = { lib, node, ... }:
    let
      clusterLib = import ../topology/_lib.nix { inherit lib; };
      # Kube nodes and devboxes share the VM plumbing (names are unique across both).
      spec = (cluster.nodes // cluster.devboxes).${node};
    in
    {
      imports = [ topModules.base topModules.users-ssh ];

      networking.hostName = node;

      microvm = {
        hypervisor = "qemu";
        inherit (spec) mem vcpu;
        # Free page reporting (topology nodes.<n>.balloon): the RAM the guest frees goes back
        # to the host; without it, a page the guest touched stays the VM's for good.
        inherit (spec) balloon;

        interfaces = [{
          type = "tap";
          id = clusterLib.tapOf node;
          mac = clusterLib.macOf node;
        }];

        shares = [
          {
            source = "/nix/store";
            mountPoint = "/nix/.ro-store";
            tag = "ro-store";
            proto = "virtiofs";
          }
          {
            source = "/var/lib/microvms/${node}/persist";
            mountPoint = "/persist";
            tag = "persist";
            proto = "virtiofs";
          }
        ];
      };

      services.openssh.hostKeys = [{
        path = "/persist/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }];

      networking.useNetworkd = true;
      networking.useDHCP = false;
      systemd.network.enable = true;
      systemd.network.networks."20-lan" = {
        # Not Type = "ether": the pods' veths would match and get the node's IP.
        matchConfig.MACAddress = clusterLib.macOf node;
        # Otherwise k3s picks the router's SLAAC IPv6 (unstable ISP prefix) as the node IP.
        networkConfig = clusterLib.lanNetworkConfig cluster spec.address // {
          IPv6AcceptRA = false;
        };
      };

      # The node's journal (k3s, kubelet, API audit) into VictoriaLogs on the monitoring host.
      # Pod logs go through Alloy instead (homelab-cluster).
      services.journald.upload = {
        enable = true;
        settings.Upload.URL =
          "http://${cluster.hosts.${cluster.monitoring.host}.address}:9428/insert/journald";
      };

      services.resolved.settings.Resolve.MulticastDNS = "yes";
      networking.firewall.allowedUDPPorts = [ 5353 ];

      systemd.network.networks."19-cni-unmanaged" = {
        matchConfig.Name = [ "veth*" "lxc*" "cilium_*" ];
        linkConfig.Unmanaged = true;
      };

      # Compressed swap in RAM: cold pages are squeezed instead of the kernel thrashing when
      # memory runs out (the nodes collapsed one after the other without swap, 2026-10-11).
      # kubelet allows it (k3s/node.nix, LimitedSwap).
      zramSwap = {
        enable = true;
        algorithm = "zstd";
        memoryPercent = 50;
      };
      # Reclaim page cache before swapping: at the default 60 the kernel kept pushing pods'
      # memory to zram and pulling it back (~20k pages/s, 160% CPU in the kernel on kube-3,
      # every probe timing out) while 1.2 GB of inactive file cache sat there (2026-10-12).
      boot.kernel.sysctl."vm.swappiness" = 10;
    };
}
