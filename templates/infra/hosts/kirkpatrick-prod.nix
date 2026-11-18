{ config, ... }:

# A dedicated prod box for one promoted app whose database is PostgreSQL.
# Copy this per promotion. Differs from keisi.nix by: env=prod, a real domain
# (not wildcard), real secrets, PostgreSQL on the box, and pgBackRest backups.
#
# (An app still on SQLite needs none of the postgres block: drop it and add a
# services.litestream entry for /var/lib/apps/<app>/<app>.db instead.)

{
  keisi.caddyEmail = "you@kirkpatrick.app"; # TODO(you)
  keisi.adminKeys = [
    # TODO(you): your SSH public key(s)
  ];
  keisi.upgradeFlake = "github:youruser/keisi-infra";

  services.keisi = {
    enable = true;
    env = "prod";
    domains.kirkpatrick = "kirkpatrick.app"; # TODO(you): the app's own TLD

    # PostgreSQL 17 on this box: a database and role named after the app,
    # reached over /run/postgresql with peer authentication. app@kirkpatrick
    # is handed APP_DATABASE_URL, so the database needs no secret.
    postgres = {
      databases = [ "kirkpatrick" ];

      # Memory defaults assume a 2 GB box; set sharedBuffers, workMem, … here
      # for a bigger one. TODO(you)

      # Continuous WAL archiving + nightly base backups to a bucket, a nightly
      # pg_dump kept 14 days on local disk, and a check that fails loudly —
      # and stops pinging — when any of it goes stale. On from the first
      # boot: see services.keisi.postgres.backup.enable.
      backup = {
        enable = true;
        s3 = {
          endpoint = "<account-id>.r2.cloudflarestorage.com"; # TODO(you)
          bucket = "your-bucket"; # TODO(you): one bucket per box
        };
        environmentFile = config.sops.secrets."pgbackrest-env".path;
        check.pingUrlFile = config.sops.secrets."backup-ping-url".path;
      };
    };
  };

  # Prod secrets → /etc/apps/kirkpatrick.env, which the app@ unit loads as
  # EnvironmentFile. sops decrypts it on the box at activation. The database
  # URL is NOT a secret and does not belong here — the unit injects it.
  sops.defaultSopsFile = ../secrets/kirkpatrick-prod.yaml; # TODO(you): sops this
  sops.secrets."kirkpatrick-env" = {
    key = "env";
    path = "/etc/apps/kirkpatrick.env";
    mode = "0400"; # systemd reads it before dropping to User=apps
    # Env vars are read once at startup: without this, an edited secret is
    # rewritten on disk and the app keeps running the old environment.
    restartUnits = [ "app@kirkpatrick.service" ];
  };

  # The bucket's credentials, as pgBackRest's own variables:
  #   PGBACKREST_REPO1_S3_KEY=<access key id>
  #   PGBACKREST_REPO1_S3_KEY_SECRET=<secret access key>
  # archive_command runs inside PostgreSQL, which reads this once at start —
  # so a rotated key must restart it, or the archiver keeps using the old one.
  sops.secrets."pgbackrest-env" = {
    key = "pgbackrest";
    restartUnits = [ "postgresql.service" ];
  };

  # A healthchecks-style ping URL and nothing else. Without it a failing
  # backup check is a failed unit on a box nobody is watching.
  sops.secrets."backup-ping-url" = { };

  system.stateVersion = "24.11";
}
