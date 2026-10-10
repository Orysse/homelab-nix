# flake-parts level: every host reads the same topology.
# address = null: DHCP; the machine stays reachable over mDNS (<name>.local).
{ lib, ... }:
let
  inherit (lib) mkOption types;
  address = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "Static IPv4, or null for DHCP.";
  };
in
{
  options.cluster = {
    network = {
      subnet = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "IPv4 network address, e.g. 192.168.1.0";
      };
      prefixLength = mkOption { type = types.nullOr (types.ints.between 1 32); default = null; };
      gateway = mkOption { type = types.nullOr types.str; default = null; };
      dns = mkOption { type = types.listOf types.str; default = [ ]; };
    };

    ingress = {
      address = mkOption {
        type = types.str;
        description = "Traefik's LoadBalancer IP (target of the router's port forwarding).";
      };
      internalAddress = mkOption {
        type = types.str;
        description = "Traefik's second LoadBalancer IP, for internal apps (*.int.<domain>). Must NOT be port-forwarded.";
      };
      pool = mkOption {
        type = types.str;
        description = "IP range MetalLB may assign (must contain `address`), e.g. 192.168.1.240-192.168.1.254.";
      };
      domain = mkOption {
        type = types.str;
        description = "Apps domain: <app>.<domain>.";
      };
    };

    storage = {
      host = mkOption {
        type = types.str;
        description = "Physical host holding all persistent data (NFS server for the cluster). The VMs keep no state.";
      };
      path = mkOption {
        type = types.str;
        default = "/srv/data";
        description = "Exported directory (btrfs subvolume @data); volumes are <path>/<namespace>_<pvc>.";
      };
    };

    database = {
      host = mkOption {
        type = types.str;
        description = "Physical host running PostgreSQL for the cluster's apps (data on its local disk, never NFS).";
      };
      databases = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "One database and one user per entry, named after the app's Kubernetes namespace. OpenBao manages the users' passwords.";
      };
    };

    oidc = {
      issuer = mkOption {
        type = types.str;
        description = "OIDC issuer the Kubernetes API trusts for people (Pocket-ID, in the cluster).";
      };
      audiences = mkOption {
        type = types.listOf types.str;
        description = "Client IDs (public values) whose ID tokens the API accepts: kubectl, Headlamp…";
      };
    };

    monitoring.host = mkOption {
      type = types.str;
      description = "Physical host running the monitoring backends (VictoriaMetrics, VictoriaLogs, Grafana). Below the cluster: it must work when the cluster does not.";
    };

    name = mkOption {
      type = types.str;
      description = "Cluster name (the `cluster` label on metrics and logs).";
    };

    vpn = {
      host = mkOption {
        type = types.str;
        description = "Physical host running the WireGuard server (target of the router's UDP forwarding).";
      };
      port = mkOption { type = types.port; default = 51820; };
      endpoint = mkOption {
        type = types.str;
        description = "Public name of the server that clients connect to (resolves to the router's IP).";
      };
      prefixLength = mkOption { type = types.ints.between 8 30; default = 24; };
      serverAddress = mkOption {
        type = types.str;
        description = "Server IP inside the tunnel, e.g. 10.250.0.1.";
      };
      serverPublicKey = mkOption {
        type = types.str;
        description = "Server public key (the private key is a sops secret of the host).";
      };
      routes = mkOption {
        type = types.listOf types.str;
        description = "Homelab networks reachable through the tunnel (clients' AllowedIPs).";
      };
      peers = mkOption {
        description = "Allowed clients: tunnel IP and public key.";
        type = types.attrsOf (types.submodule {
          options = {
            address = mkOption { type = types.str; };
            publicKey = mkOption { type = types.str; };
            access = mkOption {
              description = ''
                What this peer may reach. null: all of `routes` (admins). Otherwise only these
                address/port pairs, and nothing on the VPN host itself (guests).
              '';
              default = null;
              type = types.nullOr (types.listOf (types.submodule {
                options = {
                  address = mkOption { type = types.str; };
                  port = mkOption { type = types.port; };
                  protocol = mkOption { type = types.enum [ "tcp" "udp" ]; default = "tcp"; };
                };
              }));
            };
          };
        });
      };
    };

    gitops = {
      url = mkOption {
        type = types.str;
        description = "Git URL (HTTPS, public repository) of homelab-cluster.";
      };
      branch = mkOption { type = types.str; default = "main"; };
      path = mkOption {
        type = types.str;
        default = "./clusters/homelab";
        description = "Repository directory applied by Flux (cluster entry point).";
      };
    };

    hosts = mkOption {
      type = types.attrsOf (types.submodule {
        options = { inherit address; };
      });
    };

    nodes = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          inherit address;
          host = mkOption { type = types.str; };
          role = mkOption {
            type = types.enum [ "server" "agent" ];
            description = "Selects the k3s role.";
          };
          mem = mkOption {
            type = types.ints.positive;
            description = "RAM in MB (reserved on the host).";
          };
          vcpu = mkOption { type = types.ints.positive; };
          dataDisk = mkOption {
            type = types.ints.positive;
            default = 20480;
            description = "Size (MiB) of the k3s data volume (/var/lib/rancher), a sparse file on the host.";
          };
        };
      });
    };
  };
}
