# TEMPORAIRE (le NUC n'est pas à sa place finale) : le host sort sur Internet par son
# Wi-Fi et fait le NAT pour br0, donc pour les VMs. Le host devient la passerelle
# du subnet (cluster.network.gateway = IP du host).
#
# Identifiants Wi-Fi hors du repo : connexion impérative une fois, iwd les garde
# dans /var/lib/iwd (`iwctl station <iface> connect <SSID>`).
#
# Pour le retirer : enlever la brique du host et remettre la vraie passerelle dans topology.nix.
{
  flake.modules.nixos.wifi-uplink = { config, lib, ... }: {
    options.homelab.wifiInterface = lib.mkOption {
      type = lib.types.str;
      description = "Interface Wi-Fi servant d'uplink.";
    };

    config = {
      networking.wireless.iwd = {
        enable = true;
        # networkd gère l'IP (DHCP ci-dessous), pas iwd.
        settings.General.EnableNetworkConfiguration = false;
        # iwd réutilise l'interface créée par le noyau au lieu de la recréer
        # (le défaut NixOS n'applique ce quirk qu'avec NetworkManager).
        settings.DriverQuirks.DefaultInterface = "?*";
      };

      systemd.network.networks."30-wifi-uplink" = {
        matchConfig.Name = config.homelab.wifiInterface;
        networkConfig.DHCP = "ipv4";
        # Le host reste "online" via br0 même sans Wi-Fi.
        linkConfig.RequiredForOnline = "no";
      };

      networking.nat = {
        enable = true;
        internalInterfaces = [ "br0" ];
        externalInterface = config.homelab.wifiInterface;
      };
    };
  };
}
