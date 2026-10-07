# Fonctions pures sur la topologie (préfixe `_` : ignoré par import-tree).
{ lib }:
let
  ipToInt = ip:
    lib.foldl' (acc: octet: acc * 256 + lib.toInt octet) 0 (lib.splitString "." ip);

  inSubnet = network: ip:
    let
      size = lib.foldl' (acc: _: acc * 2) 1 (lib.range 1 (32 - network.prefixLength));
      base = ipToInt network.subnet;
    in
    builtins.div (ipToInt ip) size == builtins.div base size;

  # MAC localement administrée 02:00:00:xx:xx:xx, dérivée du nom du nœud.
  macOf = name:
    let h = builtins.hashString "sha256" "homelab-nix:${name}";
    in "02:00:00:${lib.concatStringsSep ":" [ (lib.substring 0 2 h) (lib.substring 2 2 h) (lib.substring 4 2 h) ]}";

  tapOf = name: "vm-${name}";

  duplicates = xs: lib.unique (lib.filter (x: lib.count (y: y == x) xs > 1) xs);

  # Renvoie la liste des erreurs ; vide = topologie valide.
  validate = cluster:
    let
      nodeNames = lib.attrNames cluster.nodes;
      nodes = lib.attrValues cluster.nodes;
      allIps = lib.filter (ip: ip != null)
        (map (h: h.address) (lib.attrValues cluster.hosts) ++ map (n: n.address) nodes);
      dupIps = duplicates allIps;
      dupMacs = duplicates (map macOf nodeNames);
      net = cluster.network;
      staticReady = net.subnet != null && net.prefixLength != null && net.gateway != null;
    in
    lib.optional (dupIps != [ ]) "IP dupliquées : ${toString dupIps}"
    ++ lib.optional (dupMacs != [ ]) "MAC dérivées en collision : ${toString dupMacs}"
    ++ lib.optional (allIps != [ ] && !staticReady)
      "adresses statiques présentes mais cluster.network.{subnet,prefixLength,gateway} incomplet"
    ++ lib.optionals staticReady
      (lib.concatMap (ip: lib.optional (!inSubnet net ip) "IP hors subnet : ${ip}") allIps)
    ++ lib.optional (servers cluster == [ ]) "aucun nœud avec role = \"server\""
    ++ lib.concatMap (name:
      let n = cluster.nodes.${name}; in
      lib.optional (lib.stringLength name > 12)
        "nom de nœud > 12 caractères (tap ${tapOf name} > 15) : ${name}"
      ++ lib.optional (!cluster.hosts ? ${n.host})
        "le nœud ${name} référence un host inconnu : ${n.host}"
    ) nodeNames;

  nodesOn = cluster: hostName: lib.filterAttrs (_: n: n.host == hostName) cluster.nodes;

  servers = cluster: lib.sort lib.lessThan
    (lib.attrNames (lib.filterAttrs (_: n: n.role == "server") cluster.nodes));

  # Le server qui initialise le datastore (clusterInit) ; les autres le rejoignent.
  bootstrapServer = cluster: lib.head (servers cluster);

  # Comment joindre une machine : son IP statique, sinon son nom mDNS.
  endpointOf = name: machine: if machine.address != null then machine.address else "${name}.local";

  # networkConfig systemd-networkd de l'interface LAN d'une machine (host ou VM).
  lanNetworkConfig = cluster: address:
    { MulticastDNS = true; }
    // (if address == null then {
      DHCP = "ipv4";
    } else {
      Address = [ "${address}/${toString cluster.network.prefixLength}" ];
      DNS = cluster.network.dns;
      DHCP = "no";
    }
    # Pas de route par défaut vers soi-même (cas où le host est la passerelle).
    // lib.optionalAttrs (cluster.network.gateway != address) {
      Gateway = cluster.network.gateway;
    });
in
{
  inherit macOf tapOf validate nodesOn servers bootstrapServer endpointOf lanNetworkConfig;
}
