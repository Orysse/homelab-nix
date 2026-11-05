{
  cluster = {
    name = "homelab";

    # Router DHCP: .10–.150. Outside DHCP:
    #   .200–.209  physical hosts (host id N = .20N)
    #   .210–.239  k3s VMs (kube-N = .21N), then extra VMs
    #   .240–.254  LoadBalancers (Cilium LB-IPAM)
    network = {
      subnet = "192.168.1.0";
      prefixLength = 24;
      gateway = "192.168.1.1";
      dns = [ "192.168.1.1" ];
    };

    # Hardware only. The VM of nuc1 is kube-0 (.210); its memory is derived from `ram`
    # (_lib.nix, reserves) and printed by:
    #   nix eval .#nixosConfigurations.nuc1.config.microvm.vms.kube-0.config.config.microvm.mem
    hosts.nuc1 = { id = 0; ram = 16384; cores = 12; };

    clusters.homelab = {
      servers = [ "nuc1" ];

      # Router port forwarding: TCP 80/443 -> address.
      ingress = {
        address = "192.168.1.240";
        internalAddress = "192.168.1.241"; # VPN/LAN only: not port-forwarded
        lapiAddress = "192.168.1.242";     # CrowdSec LAPI, for the hosts' firewall bouncer
        pool = "192.168.1.240-192.168.1.254";
        domain = "abe.lc";
      };

      # People log in to the Kubernetes API through Pocket-ID (clients created in its UI).
      oidc = {
        issuer = "https://auth.abe.lc";
        audiences = [
          "46031658-1b1a-4d3b-8bfa-82dfaf67d4c4"   # kubernetes (kubectl oidc-login, public)
          "da937e7f-357b-4310-831e-d09dfe89aa8c"   # headlamp
        ];
      };

      gitops.url = "https://github.com/Orysse/homelab-cluster";
    };

    # Where each host service runs. All persistent data lives on the nfs host (NFS to the
    # nodes, btrfs snapshots): the VMs stay disposable.
    services = {
      vpn.on = "nuc1";          # WireGuard (router: UDP 51820 -> nuc1), Tailscale (UDP 41641), ddclient
      monitoring.on = "nuc1";   # metrics, logs, alerts: below the cluster, it works when the cluster does not
      # Garage (S3) for PostgreSQL backups, until the NAS arrives (then an address, not a host).
      backup.on = "nuc1";
      scanner.on = [ "nuc1" ];  # trivy; a list, so it can run nowhere
      nfs.on = "nuc1";          # temporary, until phase 4
      postgres.on = "nuc1";     # apps' PostgreSQL on a local disk (SQLite on NFS corrupts); temporary
    };

    vms = { };

    # One database per namespace; OpenBao owns the passwords (homelab-cluster: openbao/).
    database = {
      databases = [ "pocket-id" "monitoring" "umami" "headscale" "open-webui" ];
      # Grafana (its user "monitoring") shows Umami's stats: the analytics tables only, not
      # Umami's users or API keys.
      readers = [
        { role = "monitoring"; database = "umami"; tables = [ "website" "website_event" "session" ]; }
      ];
    };

    # 10.100.0.0/24 is already used by the school's cyber range tunnel.
    # routes: .192/26 only; the whole /24 would shadow remote LANs in 192.168.1.x.
    vpn = {
      endpoint = "vpn.abe.lc";
      serverAddress = "10.250.0.1";
      serverPublicKey = "TNugHNt2qsBT5T/3ac1HWzXFzrw24rWu1l0uCKZhWEM=";
      routes = [ "192.168.1.192/26" ];
      # Tailscale (control server: Headscale in the cluster, hs.abe.lc) for everyday use, nuc1
      # as subnet router (tailscale.nix); the WireGuard peers below stay as break-glass (no
      # dependency on the cluster or Pocket-ID).
      peers = {
        thinkpad = { address = "10.250.0.2"; publicKey = "Gc7BSQE6PfLylPg2Zam2r3a9aaANhhc0nY07bPNQWS4="; };
        # Friends (cluster admins through Pocket-ID): the Kubernetes API and the internal
        # gateway (*.int), not the host (no SSH) nor the LAN.
        # lenny = {
        #   address = "10.250.0.10";
        #   publicKey = "<his WireGuard public key>";
        #   access = [
        #     { address = "192.168.1.210"; port = 6443; }
        #     { address = "192.168.1.241"; port = 443; }
        #   ];
        # };
      };
    };
  };
}
