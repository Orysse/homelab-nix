# PostgreSQL for the cluster's apps, on the database host's local disk (subvolume @db,
# snapshotted by btrbk): databases need real file locking, which NFS does not give.
# One database + one user per app, named after its Kubernetes namespace (topology).
# OpenBao owns the app users' passwords (database secrets engine, static roles): it logs in
# as "openbao" and sets them; the apps get them through External Secrets. Nobody else
# knows them. Only the nodes may connect, with a password (scram-sha-256).
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.postgres = { config, lib, pkgs, ... }:
    let
      nodeIPs = lib.filter (a: a != null) (lib.mapAttrsToList (_: n: n.address) cluster.nodes);
      dbs = cluster.database.databases;
      cdbs = cluster.database.collateC;
      psql = "${config.services.postgresql.package}/bin/psql";
    in
    lib.mkIf (cluster.database.host == config.networking.hostName) {
      services.postgresql = {
        enable = true;
        package = pkgs.postgresql_18;
        enableTCPIP = true;
        settings.password_encryption = "scram-sha-256";
        # The C-collation databases are created below (ensureDatabases cannot set a locale).
        ensureDatabases = lib.subtractLists cdbs dbs;
        ensureUsers =
          map (db: { name = db; ensureDBOwnership = !(lib.elem db cdbs); }) dbs
          ++ [{ name = "openbao"; ensureClauses = { login = true; createrole = true; }; }];
        # Local admin through the unix socket (peer); the nodes with a password only.
        authentication = lib.mkForce (''
          local all all peer
        '' + lib.concatMapStrings (ip: "host all all ${ip}/32 scram-sha-256\n") nodeIPs);
      };

      # OpenBao's own password comes from sops; it also needs ADMIN on the app roles to set
      # their passwords (PostgreSQL 16+ no longer lets CREATEROLE alter roles it did not create).
      sops.secrets.postgres-openbao-password.owner = "postgres";
      systemd.services.postgresql-openbao = {
        description = "Give OpenBao its PostgreSQL password and admin rights on the app roles";
        after = [ "postgresql-setup.service" ];
        requires = [ "postgresql-setup.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; User = "postgres"; };
        # The sops password is only a bootstrap value: once OpenBao has rotated it
        # (rotate-root), only OpenBao knows the real one, so it is set only when missing.
        script = ''
          missing=$(${psql} -At <<'SQL'
          SELECT rolpassword IS NULL FROM pg_authid WHERE rolname = 'openbao';
          SQL
          )
          if [ "$missing" = t ]; then
            ${psql} -v ON_ERROR_STOP=1 -v pw="$(cat ${config.sops.secrets.postgres-openbao-password.path})" <<'SQL'
          ALTER ROLE openbao PASSWORD :'pw';
          SQL
          fi
          ${psql} -v ON_ERROR_STOP=1 <<'SQL'
          ${lib.concatMapStrings (db: ''GRANT "${db}" TO openbao WITH ADMIN OPTION;'' + "\n") dbs}
          SQL
        '';
      };

      # Databases that need the C collation, owned by their user like the others.
      systemd.services.postgresql-collate-c = lib.mkIf (cdbs != [ ]) {
        description = "Create the PostgreSQL databases that need the C collation";
        after = [ "postgresql-setup.service" ];
        requires = [ "postgresql-setup.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; User = "postgres"; };
        # \gexec runs the CREATE only when the SELECT returns it (database missing).
        script = lib.concatMapStrings (db: ''
          ${psql} -v ON_ERROR_STOP=1 <<'SQL'
          SELECT format('CREATE DATABASE %I OWNER %I TEMPLATE template0 ENCODING %L LC_COLLATE %L LC_CTYPE %L',
                        '${db}', '${db}', 'UTF8', 'C', 'C')
          WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${db}')\gexec
          SQL
        '') cdbs;
      };

      # Read-only access across apps (topology database.readers): listed tables only. Run
      # again at every switch; GRANT is idempotent.
      systemd.services.postgresql-readers = lib.mkIf (cluster.database.readers != [ ]) {
        description = "Grant apps read-only access to other apps' tables";
        after = [ "postgresql-setup.service" ];
        requires = [ "postgresql-setup.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; User = "postgres"; };
        script = lib.concatMapStrings (r: ''
          ${psql} -v ON_ERROR_STOP=1 -d '${r.database}' <<'SQL'
          GRANT CONNECT ON DATABASE "${r.database}" TO "${r.role}";
          GRANT USAGE ON SCHEMA public TO "${r.role}";
          GRANT SELECT ON ${lib.concatMapStringsSep ", " (t: ''public."${t}"'') r.tables} TO "${r.role}";
          SQL
        '') cluster.database.readers;
      };

      networking.firewall.extraCommands = lib.concatMapStrings
        (ip: "iptables -A nixos-fw -p tcp -s ${ip} --dport 5432 -j nixos-fw-accept\n")
        nodeIPs;

      # Snapshotted with @data by the storage host's btrbk (same host today).
      services.btrbk.instances.data.settings.volume."/mnt/btrfs".subvolume."@db" =
        lib.mkIf (cluster.storage.host == config.networking.hostName) { };
    };
}
