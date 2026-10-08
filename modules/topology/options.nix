# Schéma de la topologie. Déclaré au niveau flake-parts pour que tous les hosts
# lisent la même donnée (seule source de vérité : topology.nix).
#
# `address = null` (défaut) => la machine prend son IP en DHCP. Les noms restent
# résolvables en mDNS (<nom>.local), ce qui suffit à k3s pour trouver le server.
{ lib, ... }:
let
  inherit (lib) mkOption types;
  address = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "IPv4 statique, ou null pour DHCP.";
  };
in
{
  options.cluster = {
    # Utilisé seulement par les machines à adresse statique.
    network = {
      subnet = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Adresse réseau IPv4, ex. 192.168.1.0";
      };
      prefixLength = mkOption { type = types.nullOr (types.ints.between 1 32); default = null; };
      gateway = mkOption { type = types.nullOr types.str; default = null; };
      dns = mkOption { type = types.listOf types.str; default = [ ]; };
    };

    # Point d'entrée HTTP(S) du cluster : une IP annoncée par MetalLB, portée par Traefik.
    ingress = {
      address = mkOption {
        type = types.str;
        description = "IP du LoadBalancer de Traefik (cible du futur NAT/PAT de la box).";
      };
      pool = mkOption {
        type = types.str;
        description = "Plage d'IP que MetalLB peut attribuer (doit contenir `address`), ex. 192.168.1.240-192.168.1.254.";
      };
      domain = mkOption {
        type = types.str;
        description = "Domaine des apps : <app>.<domain>.";
      };
    };

    name = mkOption {
      type = types.str;
      description = "Nom du cluster (tags d'observabilité, clusterName Datadog).";
    };

    datadog.site = mkOption {
      type = types.str;
      description = "Site Datadog (région du compte), ex. datadoghq.com (US1), datadoghq.eu.";
    };

    # VPN d'administration (WireGuard) : serveur sur un host physique, indépendant de k3s.
    vpn = {
      host = mkOption {
        type = types.str;
        description = "Host physique qui porte le serveur WireGuard (cible du PAT UDP de la box).";
      };
      port = mkOption { type = types.port; default = 51820; };
      endpoint = mkOption {
        type = types.str;
        description = "Nom public du serveur, que les clients contactent (résout vers l'IP de la box).";
      };
      prefixLength = mkOption { type = types.ints.between 8 30; default = 24; };
      serverAddress = mkOption {
        type = types.str;
        description = "IP du serveur dans le tunnel, ex. 10.100.0.1.";
      };
      serverPublicKey = mkOption {
        type = types.str;
        description = "Clé publique du serveur (la privée est un secret sops du host).";
      };
      routes = mkOption {
        type = types.listOf types.str;
        description = "Réseaux du homelab joignables par le tunnel (AllowedIPs des clients).";
      };
      peers = mkOption {
        description = "Clients autorisés : IP dans le tunnel et clé publique.";
        type = types.attrsOf (types.submodule {
          options = {
            address = mkOption { type = types.str; };
            publicKey = mkOption { type = types.str; };
          };
        });
      };
    };

    # Repo GitOps suivi par Flux (contenu du cluster : plateforme et apps).
    gitops = {
      url = mkOption {
        type = types.str;
        description = "URL git (HTTPS, repo public) du repo homelab-cluster.";
      };
      branch = mkOption { type = types.str; default = "main"; };
      path = mkOption {
        type = types.str;
        default = "./clusters/homelab";
        description = "Dossier du repo que Flux applique (point d'entrée du cluster).";
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
            description = "Sélectionne le rôle k3s.";
          };
          mem = mkOption {
            type = types.ints.positive;
            description = "RAM en Mo (réservée sur le host).";
          };
          vcpu = mkOption { type = types.ints.positive; };
          dataDisk = mkOption {
            type = types.ints.positive;
            default = 20480;
            description = "Taille (Mio) du volume de données k3s (/var/lib/rancher), fichier creux sur le host.";
          };
        };
      });
    };
  };
}
