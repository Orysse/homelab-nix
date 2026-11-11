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
    # dataDisk 64 GiB: the paperclip image alone unpacks to ~10 GB (2026-11-07, 84% of 32 GiB).
    # microvm.nix does not grow an existing image: docs/runbooks/grow-vm-disk.md.
    hosts.nuc1 = { id = 0; ram = 16384; cores = 12; dataDisk = 65536; };

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

    # Where each host service runs.
    services = {
      vpn.on = "nuc1";          # WireGuard (router: UDP 51820 -> nuc1), Tailscale (UDP 41641), ddclient
      monitoring.on = "nuc1";   # metrics, logs, alerts: below the cluster, it works when the cluster does not
      # Garage (S3) for PostgreSQL backups, until the NAS arrives (then an address, not a host).
      backup.on = "nuc1";
      scanner.on = [ "nuc1" ];  # trivy; a list, so it can run nowhere
    };

    # LAN appliances (docs/specs/2026-11-11-lan-guests.md): their own address and firewall,
    # on the LAN only (nothing is port-forwarded to them).
    guests.music = {
      on = "nuc1";
      address = "192.168.1.220";
      mem = 512;
      # Music Assistant: Navidrome (https://navidrome.int.abe.lc, Subsonic credentials set in
      # its UI) played on the Chromecast Audio, the Google Homes and the AirPlay devices.
      # openFirewall: TCP 8097 (stream), 5000/7000 and UDP 32768-65535 (AirPlay).
      module = {
        services.music-assistant = {
          enable = true;
          openFirewall = true;
          providers = [ "airplay" "chromecast" "opensubsonic" ];
        };
        # The UI, only from the internal Gateway: music.int.abe.lc, behind Pocket-ID (oauth2-proxy)
        # then its own login
        # (homelab-cluster apps/music/music-assistant.yaml). Envoy reaches it from kube-0's address.
        networking.firewall.extraCommands =
          "iptables -A nixos-fw -p tcp -s 192.168.1.210 --dport 8095 -j nixos-fw-accept";
      };
    };

    # Home Assistant at ha.int.abe.lc (homelab-cluster apps/home-assistant), login through
    # Pocket-ID (auth_oidc, public client `home-assistant` with PKCE: no secret). Integrations
    # are set in its UI; one that needs a Python package not listed here fails until added.
    guests.home = {
      on = "nuc1";
      address = "192.168.1.221";
      mem = 1024;
      module = { pkgs, ... }: {
        services.home-assistant = {
          enable = true;
          extraComponents = [ "default_config" "isal" "met" "radio_browser" "esphome" "cast" "apple_tv" "music_assistant" ];
          customComponents = [ pkgs.home-assistant-custom-components.auth_oidc ];
          config = {
            default_config = { };
            homeassistant = {
              name = "Maison";
              time_zone = "Europe/Paris";
              unit_system = "metric";
              external_url = "https://ha.int.abe.lc";
              internal_url = "https://ha.int.abe.lc";
            };
            http = {
              use_x_forwarded_for = true;
              trusted_proxies = [ "192.168.1.210" ];   # the Gateway (Envoy, from kube-0)
              # The local owner account takes passwords: ban a client IP after 5 failures
              # (ip_bans.yaml in /var/lib/hass, delete a line there to lift a ban).
              login_attempts_threshold = 5;
            };
            auth_oidc = {
              client_id = "home-assistant";
              discovery_url = "https://auth.abe.lc/.well-known/openid-configuration";
              display_name = "Pocket-ID";
              roles.admin = "admins";
            };
          };
        };
        networking.firewall.extraCommands =
          "iptables -A nixos-fw -p tcp -s 192.168.1.210 --dport 8123 -j nixos-fw-accept";
      };
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
