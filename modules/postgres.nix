{ config, lib, pkgs, ... }:

# services.keisi.postgres — PostgreSQL for the apps that have outgrown SQLite.
#
# Opt-in and per app. List an app here and this box gains a PostgreSQL server
# with a database and an owning role named after the app, reachable only over
# the unix socket in /run/postgresql, and `app@<app>` is told where to find
# it. An app that is NOT listed is untouched — same unit text, same
# environment — so SQLite and Postgres apps can share a box.
#
#   services.keisi.postgres.databases = [ "kirkpatrick" ];
#
# Backups live next door in postgres-backup.nix (services.keisi.postgres.backup).

let
  inherit (lib) mkOption mkIf mkForce types literalExpression concatMapStrings listToAttrs nameValuePair;
  cfg = config.services.keisi;
  pg = cfg.postgres;
in
{
  options.services.keisi.postgres = {
    databases = mkOption {
      type = types.listOf (types.strMatching "[a-z][a-z0-9_-]*");
      default = [ ];
      example = [ "kirkpatrick" ];
      description = ''
        Apps whose database is PostgreSQL. Each entry is an app name, exactly
        as in `app@<name>`, and gets:

        - a database `<name>` owned by a role `<name>` (never a superuser);
        - permission for the shared `apps` OS user to log in as that role, and
          only that role, over the unix socket — peer authentication through
          an ident map, so there is no password to store or rotate;
        - `APP_DATABASE_URL=postgres:///<name>?host=/run/postgresql&user=<name>`
          in `app@<name>`, and an ordering after PostgreSQL.

        Empty (the default) leaves the box exactly as it was: no PostgreSQL
        and no change to any unit.

        Removing a name does NOT drop its database or role — that is a
        deliberate manual step (`DROP DATABASE`), never a side effect of a
        rebuild.
      '';
    };

    package = mkOption {
      type = types.package;
      default = pkgs.postgresql_17;
      defaultText = literalExpression "pkgs.postgresql_17";
      description = ''
        The PostgreSQL package. Pinned here rather than left to the nixpkgs
        default, which follows `system.stateVersion` — a host still declaring
        "24.11" would silently get PostgreSQL 16.

        A major-version bump is not a rebuild: the data directory is
        per-major (`/var/lib/postgresql/<major>`), so the new version starts
        EMPTY beside the old one. Upgrade with pg_upgrade or dump/restore,
        then change this.
      '';
    };

    initdbArgs = mkOption {
      type = types.listOf types.str;
      default = [
        "--encoding=UTF8"
        "--locale=C.UTF-8"
        "--locale-provider=builtin"
        "--builtin-locale=C.UTF-8"
        "--data-checksums"
      ];
      description = ''
        Arguments for `initdb`. They apply ONCE, when the cluster is first
        created; changing them later does nothing to an existing cluster.

        The defaults are chosen for apps arriving from SQLite:

        - `builtin` / `C.UTF-8` sorts text by code point — the same order as
          SQLite's default BINARY collation, so `ORDER BY` does not change
          under the app — while `lower()`/`upper()` still understand all of
          Unicode. Unlike a libc locale (en_US.UTF-8) it does not depend on
          glibc, whose collation changes between NixOS releases silently
          corrupt text indexes built under the old one.
        - `--locale=C.UTF-8` pins the remaining libc categories too, instead
          of inheriting whatever `LANG` the machine happens to have.
        - `--data-checksums` lets PostgreSQL, and pgBackRest during every
          backup, notice a page the disk returned damaged.

        Development (Forge) must initialise its cluster the same way, or
        sort order differs between dev and prod.
      '';
    };

    # ── Memory ───────────────────────────────────────────────────────────
    # PostgreSQL's own defaults assume it owns the machine. On a keisi box it
    # shares a small VPS with the app and Caddy, so these are explicit, and
    # sized for a 2 GB box. Raise them on the host when the box is bigger.
    sharedBuffers = mkOption {
      type = types.str;
      default = "256MB";
      description = ''
        `shared_buffers` — PostgreSQL's own page cache, allocated at start.
        Roughly an eighth of RAM here: half the usual quarter, because the
        app and the kernel's page cache need the rest.
      '';
    };

    effectiveCacheSize = mkOption {
      type = types.str;
      default = "768MB";
      description = ''
        `effective_cache_size` — how much memory the planner should assume is
        available for caching (shared_buffers plus the kernel's page cache).
        A hint only; it allocates nothing.
      '';
    };

    workMem = mkOption {
      type = types.str;
      default = "8MB";
      description = ''
        `work_mem` — memory for ONE sort or hash step. A single query can use
        several, and every connection can run one, so the worst case is this
        times a multiple of `maxConnections`. This is the setting that gets a
        small box OOM-killed; raise it for one session
        (`SET work_mem = '64MB'`) rather than globally.
      '';
    };

    maintenanceWorkMem = mkOption {
      type = types.str;
      default = "64MB";
      description = ''
        `maintenance_work_mem` — memory for VACUUM, CREATE INDEX and adding
        foreign keys. Each autovacuum worker (three by default) may use this
        much.
      '';
    };

    maxConnections = mkOption {
      type = types.ints.positive;
      default = 40;
      description = ''
        `max_connections`. Every connection is a process with its own memory,
        so on a small box this is a memory setting too. An app holds a pool
        of a handful; three slots are always kept back for the superuser
        (backups, the health check, you).
      '';
    };
  };

  config = mkIf (cfg.enable && pg.databases != [ ]) {
    assertions = [{
      assertion = !(lib.any (db: lib.elem db [ "postgres" "template0" "template1" ]) pg.databases);
      message = "services.keisi.postgres.databases: postgres, template0 and template1 are PostgreSQL's own databases, not apps.";
    }];

    services.postgresql = {
      enable = true;
      package = pg.package;
      initdbArgs = pg.initdbArgs;

      # A database per app, owned by a role of the same name. The owner can
      # create its own schema — the app runs its migrations at startup — and
      # nothing else: it cannot see another app's database and is not a
      # superuser.
      ensureDatabases = pg.databases;
      ensureUsers = map (db: { name = db; ensureDBOwnership = true; }) pg.databases;

      # Who may be whom. Apps all run as the one OS user `apps`, which is not
      # the name of any database role, so plain peer authentication would
      # refuse them. This map lets `apps` — and nobody else — log in as
      # exactly the listed roles, each to its own database. pg_hba takes the
      # first line that matches, so an OS user that is not in the map is
      # refused here rather than falling through to a looser rule.
      #
      # These lines go above the nixpkgs defaults, which stay: `postgres`
      # (root's way in, via `sudo -u postgres psql`) and same-name peer
      # login.
      authentication = concatMapStrings
        (db: ''
          local "${db}" "${db}" peer map=keisi
        '')
        pg.databases;
      identMap = concatMapStrings
        (db: ''
          keisi apps "${db}"
        '')
        pg.databases;

      settings = {
        # No TCP listener at all — not even on localhost. The nixpkgs module
        # defaults to "localhost"; empty means the unix socket is the only
        # way in, so there is no port to firewall and no password
        # authentication to get wrong.
        listen_addresses = mkForce "";

        max_connections = pg.maxConnections;
        shared_buffers = pg.sharedBuffers;
        effective_cache_size = pg.effectiveCacheSize;
        work_mem = pg.workMem;
        maintenance_work_mem = pg.maintenanceWorkMem;

        # Explicit, because the NixOS-generated postgresql.conf replaces the
        # one initdb writes — which is where the system time zone would
        # otherwise have been recorded. Sessions and logs are UTC on every
        # box, whatever the machine's own zone.
        timezone = "UTC";
        log_timezone = "UTC";
      };
    };

    # ── Tell each listed app where its database is ───────────────────────
    # A per-instance drop-in (app@<name>.service.d/overrides.conf), not a
    # change to the shared app@ template. Two reasons:
    #
    #  * Scope. `Environment=APP_DATABASE_URL=postgres:///%i?…` in the
    #    template would hand EVERY app a URL, including the SQLite ones,
    #    pointing at a database that does not exist. An app that picks its
    #    driver by whether that variable is set — which is exactly how a
    #    ported app behaves — would then try PostgreSQL and fail to start.
    #  * Blast radius. nixos-rebuild restarts every running instance of a
    #    template whose text changed. Leaving the template byte-identical
    #    means enabling PostgreSQL for one app restarts that app only.
    #
    # Wants=, not Requires=. When a rebuild changes postgresql.conf, NixOS
    # stops and then starts PostgreSQL; Requires= would propagate that stop
    # to the app, and nothing starts a template instance again (it is wanted
    # by no target). With Wants= the app stays up, loses its connections for
    # the few seconds the restart takes, and reconnects. If PostgreSQL is
    # down when the app starts, the app fails its health gate and systemd
    # retries it — loudly, in the journal and in keisi-deploy's exit status.
    #
    # After postgresql.target rather than postgresql.service: the target is
    # reached only once postgresql-setup has created the role and database.
    systemd.services = listToAttrs (map
      (db: nameValuePair "app@${db}" {
        overrideStrategy = "asDropin";
        after = [ "postgresql.target" ];
        wants = [ "postgresql.target" ];
        environment.APP_DATABASE_URL = "postgres:///${db}?host=/run/postgresql&user=${db}";
      })
      pg.databases);
  };
}
