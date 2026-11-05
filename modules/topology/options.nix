# flake-parts level: every host reads the same topology.
# Hosts are hardware only. Workloads (the cluster, host services, extra VMs) are placed on
# hosts by name; addresses, VM names, MACs and the k3s VM's memory are derived (_lib.nix).
{ lib, ... }:
let
  inherit (lib) mkOption types;

  ingress = {
    address = mkOption {
      type = types.str;
      description = "The public Gateway's LoadBalancer IP (target of the router's port forwarding).";
    };
    lapiAddress = mkOption {
      type = types.str;
      description = "LoadBalancer IP of CrowdSec's LAPI, for the firewall bouncer on the physical hosts. In the pool, not port-forwarded.";
    };
    internalAddress = mkOption {
      type = types.str;
      description = "Second LoadBalancer IP (Gateway internal), for internal apps (*.int.<domain>). Must NOT be port-forwarded.";
    };
    pool = mkOption {
      type = types.str;
      description = "IP range Cilium may assign to LoadBalancer Services (must contain `address`), e.g. 192.168.1.240-192.168.1.254.";
    };
    domain = mkOption {
      type = types.str;
      description = "Apps domain: <app>.<domain>.";
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
in
{
  options.cluster = {
    name = mkOption {
      type = types.str;
      description = "Name of the cluster in `clusters` (also the `cluster` label on metrics and logs).";
    };

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

    hosts = mkOption {
      description = ''
        Physical machines, hardware only. A host's address is `<subnet>.20<id>`, and the VM of
        its k3s node `kube-<id>` is `<subnet>.21<id>`.
      '';
      type = types.attrsOf (types.submodule {
        options = {
          id = mkOption {
            type = types.ints.between 0 9;
            description = "Stable identity, given in join order (nuc1 = 0).";
          };
          ram = mkOption { type = types.ints.positive; description = "Physical RAM (MB)."; };
          cores = mkOption { type = types.ints.positive; description = "vCPUs of the host's k3s VM."; };
          dataDisk = mkOption {
            type = types.ints.positive;
            default = 32768;
            description = "Size (MiB) of the k3s data volume (/var/lib/rancher), a sparse file on the host.";
          };
          localDisk = mkOption {
            type = types.ints.positive;
            default = 20480;
            description = "Size (MiB) of the volume for local PersistentVolumes (/var/lib/local-volumes): databases and other data that must not sit on NFS. A sparse file on the host, kept across VM restarts.";
          };
        };
      });
    };

    clusters = mkOption {
      description = "k3s clusters: one k3s VM per listed host.";
      type = types.attrsOf (types.submodule {
        options = {
          servers = mkOption {
            type = types.listOf types.str;
            description = "Hosts whose VM is a k3s server (etcd). An odd count; the first (sorted) bootstraps.";
          };
          agents = mkOption {
            type = types.nullOr (types.listOf types.str);
            default = null;
            description = "Hosts whose VM is an agent. null: every host that is not a server.";
          };
          inherit gitops oidc ingress;
        };
      });
    };

    services = mkOption {
      description = ''
        Where each host service runs. Placement is always written: nothing moves when a host is
        added. A singleton (vpn, monitoring, backup, nfs, postgres) names one host; `scanner`
        is a list, so it can run nowhere.
      '';
      type = types.attrsOf (types.submodule {
        options.on = mkOption { type = types.either types.str (types.listOf types.str); };
      });
    };

    vms = mkOption {
      description = "Extra microVMs (not the k3s node), placed on a host.";
      default = { };
      type = types.attrsOf (types.submodule {
        options = {
          on = mkOption { type = types.str; description = "Host that runs the VM."; };
          mem = mkOption { type = types.ints.positive; description = "RAM in MB, taken from the host's k3s VM."; };
          address = mkOption { type = types.str; description = "Static IPv4 on the LAN, outside .21x, the DHCP range and the LB pool."; };
          module = mkOption { type = types.deferredModule; default = { }; description = "NixOS module of the guest."; };
        };
      });
    };

    storage.path = mkOption {
      type = types.str;
      default = "/srv/data";
      description = "Exported directory (btrfs subvolume @data); volumes are <path>/<namespace>_<pvc>.";
    };

    database = {
      databases = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "One database and one user per entry, named after the app's Kubernetes namespace. OpenBao manages the users' passwords.";
      };
      readers = mkOption {
        type = types.listOf (types.submodule {
          options = {
            role = mkOption { type = types.str; description = "Existing app user (one of `databases`)."; };
            database = mkOption { type = types.str; description = "Database it may read."; };
            tables = mkOption { type = types.listOf types.str; description = "Tables it may SELECT (only these: never a whole schema)."; };
          };
        });
        default = [ ];
        description = "Read-only access of one app to some tables of another app's database.";
      };
    };

    vpn = {
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
  };
}
