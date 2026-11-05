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

  lastOctet = ip: lib.toInt (lib.last (lib.splitString "." ip));

  # 02:00:00: locally administered prefix expected by microvm.nix.
  macOf = name:
    let h = builtins.hashString "sha256" "homelab-nix:${name}";
    in "02:00:00:${lib.concatStringsSep ":" [ (lib.substring 0 2 h) (lib.substring 2 2 h) (lib.substring 4 2 h) ]}";

  tapOf = name: "vm-${name}";

  duplicates = xs: lib.unique (lib.filter (x: lib.count (y: y == x) xs > 1) xs);

  toList = on: if builtins.isList on then on else [ on ];

  # RAM kept from a host's k3s VM, in MB, measured on nuc1 (2026-11-05, hc docs/measurements.md).
  # base: kernel and slab, systemd, QEMU, virtiofsd, btrfs page cache, nix builds during a
  # deploy, and 3 GB of headroom (a guest's page cache is never given back: no balloon).
  # The services are the peaks of the units; monitoring grows with every host it scrapes
  # (estimated, not measured: measure again in the add-host runbook).
  reserves = {
    # 4224 + the 128 the host PostgreSQL used to take (removed with the NFS host): the k3s VM
    # stays at the approved 9216 MB; the 128 are headroom for the host.
    base = 4352;
    vpn = 128;
    monitoring = 1280;
    monitoringPerHost = 128;
    backup = 128;
    scanner = 1280;
  };

  # Floor for a k3s VM: the size approved for nuc1 (9216) minus 25%. Below it the check
  # fails instead of starving the cluster.
  memFloor = 6912;

  singletons = [ "vpn" "monitoring" "backup" ];

  octets = cluster: lib.concatStringsSep "." (lib.take 3 (lib.splitString "." cluster.network.subnet));

  hostAddress = cluster: host: "${octets cluster}.20${toString cluster.hosts.${host}.id}";

  agentsOf = cluster: c:
    if c.agents != null then c.agents
    else lib.filter (h: !(lib.elem h c.servers)) (lib.attrNames cluster.hosts);

  k3sHostsOf = cluster: c: lib.unique (c.servers ++ agentsOf cluster c);

  # The cluster a host belongs to, or null.
  clusterOf = cluster: host:
    let names = lib.filter (n: lib.elem host (k3sHostsOf cluster cluster.clusters.${n})) (lib.attrNames cluster.clusters);
    in if names == [ ] then null else lib.head names;

  servicesOn = cluster: host:
    lib.filter (s: lib.elem host (toList cluster.services.${s}.on)) (lib.attrNames cluster.services);

  hostOf = cluster: service: cluster.services.${service}.on;

  vmsOn = cluster: host: lib.filterAttrs (_: v: v.on == host) cluster.vms;

  # RAM of a host's k3s VM: what is left after the reserves, a multiple of 64, never 2048
  # (QEMU hangs, microvm.nix#171).
  vmMem = cluster: host:
    let
      svc = servicesOn cluster host;
      monitoringExtra =
        if lib.elem "monitoring" svc
        then reserves.monitoringPerHost * (lib.length (lib.attrNames cluster.hosts) - 1)
        else 0;
      raw = cluster.hosts.${host}.ram - reserves.base
        - lib.foldl' (acc: s: acc + reserves.${s} or 0) 0 svc
        - monitoringExtra
        - lib.foldl' (acc: v: acc + v.mem) 0 (lib.attrValues (vmsOn cluster host));
      rounded = raw - lib.mod raw 64;
    in
    if rounded == 2048 then rounded - 64 else rounded;

  k3sVmOf = cluster: host:
    let
      cname = clusterOf cluster host;
      c = cluster.clusters.${cname};
      h = cluster.hosts.${host};
      name = "kube-${toString h.id}";
    in
    if cname == null then null else {
      inherit name;
      address = "${octets cluster}.21${toString h.id}";
      mac = macOf name;
      tap = tapOf name;
      k3sRole = if lib.elem host c.servers then "server" else "agent";
      isBootstrap = host == lib.head (lib.sort lib.lessThan c.servers);
      mem = vmMem cluster host;
      vcpu = h.cores;
      inherit (h) dataDisk localDisk;
    };

  # The cluster this repository deploys (`cluster.name`).
  theCluster = cluster: cluster.clusters.${cluster.name};

  # Addresses of every k3s VM of the cluster.
  vmIPs = cluster:
    map (h: (k3sVmOf cluster h).address) (k3sHostsOf cluster (theCluster cluster));

  # The bootstrap server's VM: join address of the other nodes, k8sServiceHost.
  serverAddress = cluster:
    (k3sVmOf cluster (lib.head (lib.sort lib.lessThan (theCluster cluster).servers))).address;

  validate = cluster:
    let
      net = cluster.network;
      staticReady = net.subnet != null && net.prefixLength != null && net.gateway != null;
      hostNames = lib.attrNames cluster.hosts;
      hosts = lib.attrValues cluster.hosts;
      known = h: cluster.hosts ? ${h};
      clusters = lib.attrValues cluster.clusters;
      k3sMembers = lib.concatMap (k3sHostsOf cluster) clusters;
      k3sVms = map (k3sVmOf cluster) (lib.filter known (lib.unique k3sMembers));
      extraVms = lib.mapAttrsToList (name: v: v // { inherit name; }) cluster.vms;
      allIps = map (hostAddress cluster) hostNames ++ map (v: v.address) k3sVms ++ map (v: v.address) extraVms;
      dupIps = duplicates allIps;
      dupMacs = duplicates (map (v: v.mac) k3sVms ++ map (v: macOf v.name) extraVms);
      unknownIn = what: hs: map (h: "${what} refers to an unknown host: ${h}") (lib.filter (h: !known h) hs);
    in
    if !staticReady then [ "cluster.network.{subnet,prefixLength,gateway} incomplete" ] else
    lib.optional (!(cluster.clusters ? ${cluster.name})) "cluster.name ${cluster.name} is not in clusters"
    ++ lib.optional (duplicates (map (h: h.id) hosts) != [ ]) "duplicate host ids: ${toString (duplicates (map (h: h.id) hosts))}"
    ++ lib.concatMap (h: lib.optional (h.id < 0 || h.id > 9) "host id out of range 0..9: ${toString h.id}") hosts
    ++ lib.optional (dupIps != [ ]) "duplicate IPs: ${toString dupIps}"
    ++ lib.optional (dupMacs != [ ]) "derived MAC collision: ${toString dupMacs}"
    ++ lib.concatMap (ip: lib.optional (!inSubnet net ip) "IP outside the subnet: ${ip}") allIps
    ++ lib.optional (duplicates k3sMembers != [ ]) "host in two clusters: ${toString (duplicates k3sMembers)}"
    ++ lib.concatMap (n:
      let c = cluster.clusters.${n}; in
      unknownIn "cluster ${n}" (c.servers ++ (if c.agents == null then [ ] else c.agents))
      ++ lib.optional (c.servers == [ ] || lib.mod (lib.length c.servers) 2 == 0)
        "cluster ${n}: an odd number of servers is needed, got ${toString (lib.length c.servers)}"
    ) (lib.attrNames cluster.clusters)
    ++ lib.concatMap (s:
      let on = cluster.services.${s}.on; in
      unknownIn "services.${s}.on" (toList on)
      ++ lib.optional (lib.elem s singletons && builtins.isList on) "services.${s}.on names one host, not a list"
      ++ lib.optional (!(reserves ? ${s})) "service ${s} has no entry in reserves"
    ) (lib.attrNames cluster.services)
    ++ lib.concatMap (h:
      lib.optional (cluster.hosts.${h}.localDisk < 4096)
        "localDisk below 4096 MiB on host ${h}: ${toString cluster.hosts.${h}.localDisk}"
    ) hostNames
    ++ lib.concatMap (v:
      lib.optional (v != null && v.mem < memFloor)
        "k3s VM ${v.name} would get ${toString v.mem} MB, below the floor of ${toString memFloor} (reserves too large for this host)"
    ) k3sVms
    ++ lib.concatMap (v:
      unknownIn "vms.${v.name}.on" [ v.on ]
      ++ lib.optional (lib.stringLength v.name > 12) "VM name longer than 12 characters (tap ${tapOf v.name} > 15): ${v.name}"
      ++ (let o = lastOctet v.address; in
        lib.optional (o >= 210 && o <= 219) "vms.${v.name}.address is in the k3s VM range .21x: ${v.address}"
        ++ lib.optional (o >= 10 && o <= 150) "vms.${v.name}.address is in the DHCP range: ${v.address}"
        ++ lib.optional (o >= 240 && o <= 254) "vms.${v.name}.address is in the LoadBalancer pool: ${v.address}")
    ) extraVms;

  lanNetworkConfig = cluster: address:
    { MulticastDNS = true; }
    // (if address == null then {
      DHCP = "ipv4";
    } else {
      Address = [ "${address}/${toString cluster.network.prefixLength}" ];
      DNS = cluster.network.dns;
      DHCP = "no";
    }
    # The host may itself be the gateway (Wi-Fi uplink): no route to itself.
    // lib.optionalAttrs (cluster.network.gateway != address) {
      Gateway = cluster.network.gateway;
    });
in
{
  inherit macOf tapOf validate lanNetworkConfig reserves memFloor
    hostAddress k3sVmOf servicesOn hostOf agentsOf vmIPs serverAddress vmMem theCluster;
}
