{ config, lib, pkgs, ... }:

# services.keisi.postgres.backup — backups for the PostgreSQL apps, and a
# check that says so when they stop working.
#
# The handbook's two-mechanism model (GITOPS.md §Backups), translated:
#
#   Litestream            →  pgBackRest: base backups + every WAL segment to
#                            an S3-compatible bucket. Survives losing the
#                            box; restores to any moment in the retention
#                            window; about `archiveTimeout` of exposure.
#   nightly .backup sweep →  nightly `pg_dump -Fc`, kept 14 days on local
#                            disk. Does NOT survive the box; answers "someone
#                            deleted it on Monday" with a plain file that
#                            pg_restore reads with no pgBackRest at all.
#
# And the part that matters most, because all three ways the SQLite backups
# broke reported success while doing nothing: keisi-pg-backup-check fails its
# unit — and stops pinging, if a ping URL is set — when the newest backup or
# dump is too old, when the last WAL archive attempt failed, when WAL is
# queueing, or when the disk is filling.
#
# Built on the nixpkgs modules: services.pgbackrest renders pgbackrest.conf,
# owns the `pgbackrest` user, sets archive_command and schedules the backup
# jobs. services.postgresqlBackup is NOT used: it keeps exactly two dumps
# (current and .prev), so it cannot hold fourteen days.

let
  inherit (lib) mkOption mkIf types optionalAttrs optional getExe escapeShellArg concatMapStringsSep;
  cfg = config.services.keisi;
  pg = cfg.postgres;
  b = pg.backup;

  # The nixpkgs pgbackrest module creates one stanza, `default`, for the
  # local cluster and hard-wires it into archive_command.
  stanza = "default";
  pgbackrest = getExe pkgs.pgbackrest;
  postgresql = config.services.postgresql.finalPackage;
  dataDir = config.services.postgresql.dataDir;
  databases = concatMapStringsSep " " escapeShellArg pg.databases;

  # ── First boot: stanza, then a first backup ────────────────────────────
  # Archived WAL is useless without a base backup to replay it onto, so a
  # new box must not wait until the first scheduled night to have one.
  stanzaScript = pkgs.writeShellApplication {
    name = "keisi-pg-stanza";
    runtimeInputs = [ pkgs.pgbackrest pkgs.jq ];
    text = ''
      # Idempotent: a no-op when the stanza already matches this cluster, an
      # error when the repository holds a DIFFERENT cluster's stanza — which
      # is the right answer, not something to paper over.
      pgbackrest --stanza=${stanza} stanza-create

      # `info` exits 0 even when it could not reach the repository; the
      # answer is in the status code. 0 = backups exist, 2 = a stanza with no
      # backup. Anything else is "could not tell", which must not be read as
      # either.
      status="$(pgbackrest --stanza=${stanza} --output=json info | jq -r '.[0].status.code')"
      case "$status" in
        0) ;;
        2)
          echo "keisi-pg-stanza: the repository holds no backup yet — taking the first full backup"
          pgbackrest --stanza=${stanza} --type=full backup
          ;;
        *)
          echo "keisi-pg-stanza: pgbackrest info reports status '$status' — cannot tell whether a backup exists" >&2
          exit 1
          ;;
      esac
    '';
  };

  # ── Nightly pg_dump ────────────────────────────────────────────────────
  dumpScript = pkgs.writeShellApplication {
    name = "keisi-pg-dump";
    runtimeInputs = [ postgresql pkgs.coreutils pkgs.findutils ];
    text = ''
      umask 0027
      databases=(${databases})
      for db in "''${databases[@]}"; do
        dest="${b.dump.directory}/$db/$(date +%F)"
        mkdir -p "$dest"
        # Written under another name and renamed only when complete, so a
        # dump cut short by a full disk or a restart never sits there
        # looking like a good one.
        pg_dump --format=custom --dbname="$db" --file="$dest/$db.dump.partial"
        # Reads the archive's table of contents: proof the file is a dump
        # pg_restore can open, not just bytes on disk.
        pg_restore --list "$dest/$db.dump.partial" >/dev/null
        mv "$dest/$db.dump.partial" "$dest/$db.dump"

        # Prune only after a good dump: errexit means a failure above never
        # reaches this line, so a broken night cannot eat the good ones.
        find "${b.dump.directory}/$db" -mindepth 1 -maxdepth 1 -type d \
          -mtime +${toString b.dump.keepDays} -exec rm -rf {} +
      done
    '';
  };

  # ── The check ──────────────────────────────────────────────────────────
  # Rule throughout: UNKNOWN IS FAILURE. A value that cannot be fetched or
  # parsed is reported as a problem, never skipped — a check that passes
  # when it cannot see is the failure this exists to prevent.
  checkScript = pkgs.writeShellApplication {
    name = "keisi-pg-backup-check";
    runtimeInputs = [ postgresql pkgs.pgbackrest pkgs.jq pkgs.curl pkgs.coreutils pkgs.findutils ];
    text = ''
      problems=()
      problem() {
        problems+=("$1")
        echo "PROBLEM: $1" >&2
      }

      now="$(date +%s)"
      max_backup_age=$(( ${toString b.check.maxBackupAgeHours} * 3600 ))
      max_dump_age=$(( ${toString b.check.maxDumpAgeHours} * 3600 ))

      # 1 ── WAL archiving, as PostgreSQL itself sees it ───────────────────
      # A failing archive_command does not stop the database. It makes WAL
      # pile up in pg_wal until the disk is full, and THEN the database
      # stops — so this is checked first and separately from the disk.
      query="SELECT current_setting('archive_mode'),
                    (last_failed_time IS NOT NULL
                       AND (last_archived_time IS NULL OR last_failed_time > last_archived_time)),
                    coalesce(last_failed_wal, '-'),
                    coalesce(to_char(last_failed_time, 'YYYY-MM-DD HH24:MI:SS TZ'), '-'),
                    coalesce(to_char(last_archived_time, 'YYYY-MM-DD HH24:MI:SS TZ'), 'never'),
                    (SELECT count(*) FROM pg_ls_archive_statusdir() WHERE name LIKE '%.ready')
               FROM pg_stat_archiver"
      if row="$(psql -X -A -t -F '|' -U postgres -h /run/postgresql -d postgres -c "$query")" && [ -n "$row" ]; then
        IFS='|' read -r mode failing failed_wal failed_at archived_at pending <<<"$row"
        if [ "$mode" != on ]; then
          problem "archive_mode is '$mode', not 'on': WAL is not being archived at all"
        fi
        if [ "$failing" != f ]; then
          problem "the most recent WAL archive attempt FAILED ($failed_wal at $failed_at; last success: $archived_at) — WAL is piling up in pg_wal"
        fi
        if ! [[ "$pending" =~ ^[0-9]+$ ]]; then
          problem "could not count the WAL segments waiting to be archived"
        elif (( pending > ${toString b.check.maxPendingWal} )); then
          problem "$pending WAL segments are waiting to be archived (limit ${toString b.check.maxPendingWal}; last success: $archived_at)"
        fi
      else
        problem "could not query PostgreSQL for its archiver status (is postgresql.service running?)"
      fi

      # 2 ── Newest pgBackRest backup, as the REPOSITORY sees it ───────────
      # `info` exits 0 even when the repository is unreachable — it reports
      # that in status.code — so the exit status alone proves nothing.
      if info="$(pgbackrest --stanza=${stanza} --output=json info)"; then
        status="$(jq -r '.[0].status.code // empty' <<<"$info")" || status=""
        # The stanza's message is often just "other"; the reason (host
        # unreachable, bad key) is on the repository entry.
        message="$(jq -r '[.[0].status.message // empty, (.[0].repo[]?.status.message // empty)]
          | join(" — ") | gsub("\\s+"; " ")' <<<"$info")" || message="unreadable"
        [ -n "$message" ] || message="the repository has no such stanza"
        newest="$(jq -r '[.[0].backup[]?.timestamp.stop] | max // empty' <<<"$info")" || newest=""
        errored="$(jq -r '.[0].backup[-1].error // false' <<<"$info")" || errored="unreadable"

        if [ "$status" != 0 ]; then
          problem "pgBackRest stanza '${stanza}' is not ok: $message"
        fi
        if ! [[ "$newest" =~ ^[0-9]+$ ]]; then
          problem "pgBackRest reports no completed backup in the repository"
        elif (( now - newest > max_backup_age )); then
          problem "the newest pgBackRest backup is $(( (now - newest) / 3600 ))h old (limit ${toString b.check.maxBackupAgeHours}h)"
        fi
        if [ "$errored" != false ]; then
          problem "the newest pgBackRest backup recorded errors (damaged pages?) — run: sudo keisi-pgbackrest info"
        fi
      else
        problem "pgbackrest info failed — the repository is unreachable or its credentials are wrong"
      fi

      # 3 ── Newest pg_dump of each database ───────────────────────────────
      databases=(${databases})
      for db in "''${databases[@]}"; do
        newest="$(find "${b.dump.directory}/$db" -mindepth 2 -maxdepth 2 -type f \
          -name "$db.dump" -size +0 -printf '%T@\n' 2>/dev/null | sort -n | tail -n 1 || true)"
        newest="''${newest%%.*}"
        if ! [[ "$newest" =~ ^[0-9]+$ ]]; then
          problem "no pg_dump of $db under ${b.dump.directory}/$db"
        elif (( now - newest > max_dump_age )); then
          problem "the newest pg_dump of $db is $(( (now - newest) / 3600 ))h old (limit ${toString b.check.maxDumpAgeHours}h)"
        fi
      done

      # 4 ── Disk ──────────────────────────────────────────────────────────
      for path in ${escapeShellArg dataDir} ${escapeShellArg b.dump.directory}; do
        used="$(df --output=pcent "$path" 2>/dev/null | tail -n 1 | tr -dc '0-9' || true)"
        if ! [[ "$used" =~ ^[0-9]+$ ]]; then
          problem "could not measure disk usage of $path"
        elif (( used >= ${toString b.check.maxDiskUsedPercent} )); then
          problem "the volume holding $path is $used% full (limit ${toString b.check.maxDiskUsedPercent}%)"
        fi
      done

      # ── Report ───────────────────────────────────────────────────────────
      # Healthchecks-style: a GET on success, <url>/fail on failure. The
      # success ping is the one that matters — if this box, this timer or
      # this script dies, the pings stop and the monitor raises the alarm on
      # the silence.
      url="''${KEISI_PING_URL:-}"
      if [ -z "$url" ] && [ -r "''${CREDENTIALS_DIRECTORY:-/nonexistent}/ping-url" ]; then
        url="$(tr -d '[:space:]' <"$CREDENTIALS_DIRECTORY/ping-url")"
      fi
      url="''${url%/}"

      if (( ''${#problems[@]} > 0 )); then
        if [ -n "$url" ]; then
          printf '%s\n' "''${problems[@]}" \
            | curl -fsS -m 10 --retry 3 -o /dev/null --data-binary @- "$url/fail" \
            || echo "keisi-pg-backup-check: could not deliver the failure ping" >&2
        fi
        exit 1
      fi

      echo "keisi-pg-backup-check: ok — WAL archiving, pgBackRest backup, pg_dump and disk are all within limits"
      if [ -n "$url" ]; then
        if ! curl -fsS -m 10 --retry 3 -o /dev/null "$url"; then
          echo "PROBLEM: backups are healthy but the success ping could not be delivered" >&2
          exit 1
        fi
      fi
    '';
  };

  # ── pgBackRest by hand ─────────────────────────────────────────────────
  # The repository credentials exist only in an environment file root can
  # read, so a bare `pgbackrest info` in a shell fails with a missing key.
  # This runs pgBackRest the way the units do — same user, same environment
  # file, parsed by systemd both times — for the commands a human needs:
  #   sudo keisi-pgbackrest info
  #   sudo keisi-pgbackrest check
  #   sudo keisi-pgbackrest --postgres --pg1-path=<scratch> --archive-mode=off restore
  manualScript = pkgs.writeShellApplication {
    name = "keisi-pgbackrest";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      if [ "$(id -u)" != 0 ]; then
        echo "keisi-pgbackrest: run with sudo (the repository credentials are root-only)" >&2
        exit 1
      fi

      # Backups and inspection run as `pgbackrest`. A restore writes a data
      # directory, which must belong to `postgres`: pass --postgres first.
      user=pgbackrest
      if [ "''${1:-}" = --postgres ]; then
        user=postgres
        shift
      fi

      # --stanza is given here, on the command line, and must not be repeated
      # by the caller. On the command line rather than in the environment on
      # purpose: a restore writes the options it was GIVEN into the restored
      # cluster's restore_command, and recovery cannot fetch WAL without it.
      exec systemd-run --quiet --pipe --wait --collect \
        --property=User="$user" \
        --property=EnvironmentFile=${escapeShellArg (toString b.environmentFile)} \
        ${pgbackrest} --stanza=${stanza} "$@"
    '';
  };
in
{
  options.services.keisi.postgres.backup = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Back the PostgreSQL apps up: pgBackRest to an S3-compatible bucket, a
        nightly pg_dump, and a check that fails loudly when either stops
        working.

        Turn this on for the cluster's FIRST boot. pgBackRest reads the data
        directory through group permissions that `initdb` grants only when
        it creates the cluster; enabling this on an existing cluster needs a
        one-off `chmod -R g+rX` of the data directory as well.
      '';
    };

    s3 = {
      endpoint = mkOption {
        type = types.str;
        example = "0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com";
        description = ''
          The S3 endpoint. For Cloudflare R2 this is the account endpoint
          (dashboard → R2 → the bucket → Settings → S3 API), with or without
          `https://`.
        '';
      };

      bucket = mkOption {
        type = types.str;
        example = "kirkpatrick-prod-backups";
        description = ''
          The bucket. One bucket per BOX (GITOPS.md §Backups): R2 tokens
          scope to a bucket, so a box with its own bucket and its own token
          cannot reach — or be used to destroy — another box's backups.
        '';
      };

      region = mkOption {
        type = types.str;
        default = "auto";
        description = ''The region to sign requests for. R2 uses "auto".'';
      };

      uriStyle = mkOption {
        type = types.enum [ "path" "host" ];
        default = "path";
        description = ''
          `path` requests `https://<endpoint>/<bucket>/…`; `host` requests
          `https://<bucket>.<endpoint>/…`. pgBackRest's own default is
          `host`, which suits AWS; `path` is the form that needs nothing but
          the account endpoint to resolve and to match its certificate.
        '';
      };

      path = mkOption {
        type = types.strMatching "/.+";
        default = "/pgbackrest";
        description = "Prefix inside the bucket that holds the pgBackRest repository.";
      };
    };

    environmentFile = mkOption {
      type = types.externalPath;
      example = "/run/secrets/pgbackrest-env";
      description = ''
        A file holding the bucket's credentials, as pgBackRest's own
        environment variables:

            PGBACKREST_REPO1_S3_KEY=<access key id>
            PGBACKREST_REPO1_S3_KEY_SECRET=<secret access key>

        Plain `NAME=value` lines — no quotes, no `export`. Supply it from
        sops; it must never be in the Nix store. Root-only (0400) is enough:
        systemd reads it before dropping privileges.

        It is loaded by postgresql.service (archive_command runs inside it),
        the backup jobs, the stanza unit and the check. PostgreSQL reads it
        ONCE, at start — so the secret that provides this file must restart
        postgresql.service when it changes
        (`sops.secrets.<name>.restartUnits = [ "postgresql.service" ]`), or
        rotated credentials never reach the archiver.
      '';
    };

    fullSchedule = mkOption {
      type = types.str;
      default = "Sun *-*-* 02:30:00";
      description = "When to take a full backup (systemd.time calendar expression).";
    };

    diffSchedule = mkOption {
      type = types.str;
      default = "Mon..Sat *-*-* 02:30:00";
      description = ''
        When to take a differential backup — everything changed since the
        last full. A restore needs one full, one differential and the WAL
        after it, never a chain.
      '';
    };

    retentionDays = mkOption {
      type = types.ints.positive;
      default = 14;
      description = ''
        How far back a point-in-time restore must always be able to reach.
        Full backups (with their differentials and WAL) are expired only
        once a full backup at least this old remains, so with a weekly full
        the repository holds between two and three weeks.
      '';
    };

    archiveTimeout = mkOption {
      type = types.ints.positive;
      default = 60;
      description = ''
        PostgreSQL's `archive_timeout`, in seconds: the longest a finished
        transaction waits in an unarchived WAL segment. This is the exposure
        if the box is lost. A segment is only closed early when something
        was written, so an idle database archives nothing.
      '';
    };

    dump = {
      schedule = mkOption {
        type = types.str;
        default = "*-*-* 03:30:00";
        description = "When to run the nightly pg_dump (systemd.time calendar expression).";
      };

      directory = mkOption {
        type = types.path;
        default = "/var/backups";
        description = ''
          Dumps land in `<directory>/<app>/<YYYY-MM-DD>/<app>.dump` — the
          same layout as the SQLite sweep. Local disk, on purpose: this is
          the copy you can reach when the bucket is the problem.
        '';
      };

      keepDays = mkOption {
        type = types.ints.positive;
        default = 14;
        description = "Days of nightly dumps to keep.";
      };
    };

    check = {
      schedule = mkOption {
        type = types.str;
        default = "*:0/15";
        description = "When to run the check (systemd.time calendar expression; default every 15 minutes).";
      };

      maxBackupAgeHours = mkOption {
        type = types.ints.positive;
        default = 30;
        description = ''
          Fail when the newest pgBackRest backup is older than this. A
          nightly schedule peaks at 24h plus the backup's own duration; 30
          leaves room for that and still catches one missed night.
        '';
      };

      maxDumpAgeHours = mkOption {
        type = types.ints.positive;
        default = 30;
        description = "Fail when the newest pg_dump of any listed database is older than this.";
      };

      maxPendingWal = mkOption {
        type = types.ints.unsigned;
        default = 8;
        description = ''
          Fail when more than this many WAL segments are waiting to be
          archived. Catches an archive_command that hangs or cannot keep up,
          which never registers as a failure.
        '';
      };

      maxDiskUsedPercent = mkOption {
        type = types.ints.between 1 100;
        default = 80;
        description = ''
          Fail when the volume holding the data directory, or the one
          holding the dumps, is at least this full.
        '';
      };

      pingUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "https://hc-ping.com/00000000-0000-0000-0000-000000000000";
        description = ''
          A healthchecks-style URL: requested on every passing check, and
          `<url>/fail` (with the reasons as the body) on a failing one. Set
          the monitor's period to match `schedule` so that SILENCE — a dead
          box, a stopped timer — raises the alarm too.

          This value ends up world-readable in the Nix store. Anyone who
          knows it can send passing pings; prefer `pingUrlFile`.
        '';
      };

      pingUrlFile = mkOption {
        type = types.nullOr types.externalPath;
        default = null;
        example = "/run/secrets/backup-ping-url";
        description = ''
          A file containing the ping URL and nothing else — a sops secret.
          Root-only is enough; systemd hands it to the check as a credential.
        '';
      };
    };
  };

  config = mkIf (cfg.enable && pg.databases != [ ] && b.enable) {
    assertions = [{
      assertion = b.check.pingUrl == null || b.check.pingUrlFile == null;
      message = "services.keisi.postgres.backup.check: set pingUrl or pingUrlFile, not both.";
    }];

    services.pgbackrest = {
      enable = true;

      # The only repository, so pgBackRest numbers it repo1 — which is why
      # the credentials are PGBACKREST_REPO1_*. A second repository would
      # renumber them alphabetically by name.
      repos.s3 = {
        type = "s3";
        path = b.s3.path;
        s3-endpoint = b.s3.endpoint;
        s3-bucket = b.s3.bucket;
        s3-region = b.s3.region;
        s3-uri-style = b.s3.uriStyle;
        # Stated rather than left to OpenSSL's compiled-in default, which on
        # NixOS points into the store.
        storage-ca-file = "/etc/ssl/certs/ca-certificates.crt";

        # Pack small files together: a PostgreSQL data directory is over a
        # thousand of them, and on an object store each is a request.
        bundle = true;

        retention-full-type = "time";
        retention-full = b.retentionDays;
      };

      settings = {
        compress-type = "zst";
        # Checkpoint now instead of waiting up to checkpoint_timeout for the
        # next one before the backup can begin.
        start-fast = true;
      };

      # archive-push runs once per WAL segment — every `archiveTimeout`
      # seconds on a busy database — and at the default "info" writes two
      # lines each time into PostgreSQL's log. At "warn" a healthy archiver
      # is silent and a failing one is the only thing in the journal.
      commands.archive-push.log-level-console = "warn";

      stanzas.${stanza} = {
        # Not left to libpq's compiled-in default.
        instances.localhost.socket-path = "/run/postgresql";
        jobs = {
          full = { schedule = b.fullSchedule; type = "full"; };
          diff = { schedule = b.diffSchedule; type = "diff"; };
        };
      };
    };

    # archive_mode and archive_command come from the nixpkgs pgbackrest
    # module. Changing any of this changes postgresql.conf's store path,
    # which is written into the unit, so nixos-rebuild restarts PostgreSQL —
    # there is no running daemon left holding an old configuration.
    # pgbackrest.conf has no such problem at all: pgBackRest is not a
    # daemon, and every archive-push and every job reads the file afresh.
    services.postgresql.settings.archive_timeout = b.archiveTimeout;

    systemd.services = {
      # archive_command inherits PostgreSQL's environment.
      postgresql.serviceConfig.EnvironmentFile = b.environmentFile;

      "pgbackrest-${stanza}-full".serviceConfig.EnvironmentFile = b.environmentFile;
      "pgbackrest-${stanza}-diff".serviceConfig.EnvironmentFile = b.environmentFile;

      keisi-pg-stanza = {
        description = "pgBackRest: create the stanza and take the first backup";
        wantedBy = [ "multi-user.target" ];
        after = [ "postgresql.target" "network-online.target" ];
        requires = [ "postgresql.target" ];
        wants = [ "network-online.target" ];
        # Until this succeeds every archive-push fails and WAL accumulates,
        # so it must never give up — the bucket may simply not be reachable
        # yet at boot. (Litestream once hit systemd's start limit and the box
        # ran with no replication at all: GITOPS.md, 2026-08-30.)
        unitConfig.StartLimitIntervalSec = 0;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "pgbackrest";
          Group = "pgbackrest";
          EnvironmentFile = b.environmentFile;
          ExecStart = getExe stanzaScript;
          Restart = "on-failure";
          RestartSec = "1min";
        };
      };

      keisi-pg-dump = {
        description = "Nightly pg_dump of the keisi PostgreSQL databases";
        after = [ "postgresql.target" ];
        requires = [ "postgresql.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = "postgres";
          Group = "postgres";
          ExecStart = getExe dumpScript;
        };
      };

      # Deliberately no dependency on PostgreSQL: when the database is down
      # this must still run, and fail, rather than be skipped.
      keisi-pg-backup-check = {
        description = "Fail when the PostgreSQL backups could not restore a recent state";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        environment = optionalAttrs (b.check.pingUrl != null) { KEISI_PING_URL = b.check.pingUrl; };
        serviceConfig = {
          Type = "oneshot";
          # `pgbackrest` is in the postgres group (it can read the dumps and
          # the data volume) and is mapped to the postgres database role.
          User = "pgbackrest";
          Group = "pgbackrest";
          EnvironmentFile = b.environmentFile;
          LoadCredential = optional (b.check.pingUrlFile != null) "ping-url:${toString b.check.pingUrlFile}";
          ExecStart = getExe checkScript;
        };
      };
    };

    systemd.timers = {
      keisi-pg-dump = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = b.dump.schedule;
          Persistent = true; # catch up if the box was down at the time
          RandomizedDelaySec = "15m";
        };
      };

      keisi-pg-backup-check = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = b.check.schedule;
          AccuracySec = "1min";
        };
      };
    };

    # 0750 postgres:postgres — the dumps are the whole database. The check
    # reads them through the postgres group.
    systemd.tmpfiles.rules = map (db: "d ${b.dump.directory}/${db} 0750 postgres postgres -") pg.databases;

    environment.systemPackages = [ manualScript ];
  };
}
