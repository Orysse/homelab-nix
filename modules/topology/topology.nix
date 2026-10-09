{
  cluster = {
    name = "homelab";

    datadog.site = "us5.datadoghq.com";

    # Router DHCP: .10–.150. Outside DHCP:
    #   .200–.209  physical hosts
    #   .210–.239  k3s nodes (kube-N = .21N)
    #   .240–.254  LoadBalancers (MetalLB)
    network = {
      subnet = "192.168.1.0";
      prefixLength = 24;
      gateway = "192.168.1.1";
      dns = [ "192.168.1.1" ];
    };

    # Router port forwarding: TCP 80/443 -> address.
    ingress = {
      address = "192.168.1.240";
      internalAddress = "192.168.1.241"; # VPN/LAN only: not port-forwarded
      pool = "192.168.1.240-192.168.1.254";
      domain = "abe.lc";
    };

    # All persistent data lives on this host (NFS to the nodes, btrfs snapshots): the VMs
    # stay disposable.
    storage.host = "nuc1";
    monitoring.host = "nuc1";   # metrics, logs, dashboards, alerts

    # Router port forwarding: UDP 51820 -> nuc1.
    # 10.100.0.0/24 is already used by the school's cyber range tunnel.
    # routes: .192/26 only; the whole /24 would shadow remote LANs in 192.168.1.x.
    vpn = {
      host = "nuc1";
      endpoint = "vpn.abe.lc";
      serverAddress = "10.250.0.1";
      serverPublicKey = "TNugHNt2qsBT5T/3ac1HWzXFzrw24rWu1l0uCKZhWEM=";
      routes = [ "192.168.1.192/26" ];
      peers = {
        thinkpad = { address = "10.250.0.2"; publicKey = "Gc7BSQE6PfLylPg2Zam2r3a9aaANhhc0nY07bPNQWS4="; };
      };
    };

    gitops.url = "https://github.com/Orysse/homelab-cluster";

    hosts = {
      nuc1.address = "192.168.1.200";
    };

    # mem in MB. Never exactly 2048: QEMU hangs (microvm.nix#171).
    nodes = {
      kube-1 = { host = "nuc1"; address = "192.168.1.211"; role = "server"; mem = 4000; vcpu = 2; };
      kube-2 = { host = "nuc1"; address = "192.168.1.212"; role = "agent"; mem = 3000; vcpu = 2; };
      kube-3 = { host = "nuc1"; address = "192.168.1.213"; role = "agent"; mem = 3000; vcpu = 2; };
    };
  };
}
