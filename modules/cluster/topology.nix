# LA topologie. Déplacer un nœud d'un host à l'autre = changer `host` ici.
{
  cluster = {
    # LAN de la Livebox. DHCP de la box : .10–.150 ; tout ce qui suit est hors DHCP.
    #   .200–.209  hosts physiques
    #   .210–.239  nœuds k3s (kube-N = .21N)
    #   .240–.254  réservé (futures IP de LoadBalancer)
    # `address` absent = DHCP (les noms restent joignables en mDNS : <nom>.local).
    network = {
      subnet = "192.168.1.0";
      prefixLength = 24;
      gateway = "192.168.1.1";
      dns = [ "192.168.1.1" ];
    };

    hosts = {
      nuc1.address = "192.168.1.200";
    };

    # mem en Mo, jamais exactement 2048 (QEMU se fige, microvm.nix#171).
    # 4000 + 3000 + 3000 = 10 Go réservés sur 16.
    nodes = {
      kube-1 = { host = "nuc1"; address = "192.168.1.211"; role = "server"; mem = 4000; vcpu = 2; };
      kube-2 = { host = "nuc1"; address = "192.168.1.212"; role = "agent"; mem = 3000; vcpu = 2; };
      kube-3 = { host = "nuc1"; address = "192.168.1.213"; role = "agent"; mem = 3000; vcpu = 2; };
    };
  };
}
