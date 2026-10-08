# LA topologie. Déplacer un nœud d'un host à l'autre = changer `host` ici.
{
  cluster = {
    name = "homelab";

    # Compte Datadog (offre étudiante GitHub Student Pack) : site US5.
    datadog.site = "us5.datadoghq.com";

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

    # Entrée unique du cluster. PAT de la box : 80/443 -> `address`.
    # domain : zone chez Cloudflare (registrar OVH). abe.lc et *.abe.lc pointent vers
    # l'IP publique de la box (DNS dynamique, brique ddns).
    ingress = {
      address = "192.168.1.240";
      pool = "192.168.1.240-192.168.1.254";
      domain = "abe.lc";
    };

    # VPN d'administration. PAT de la box : UDP 51820 -> nuc1 (.200).
    # Tunnel en 10.250.0.0/24 : 10.100.0.0/24 est déjà routé par un tunnel de l'école (cyber range).
    # routes : seulement .192-.255 (hosts, nœuds, entrée), pas tout le /24 : beaucoup de
    # réseaux (box, cafés) sont aussi en 192.168.1.0/24 et seraient masqués.
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

    # Contenu du cluster (plateforme, apps) : repo suivi par Flux. HTTPS : lu sans
    # identifiants (repo public).
    gitops.url = "https://github.com/Orysse/homelab-cluster";

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
