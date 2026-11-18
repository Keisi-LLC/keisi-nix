{ lib
, writeShellApplication
, sqlite
, curl
, coreutils
, systemd
, util-linux
  # The box's PostgreSQL (client tools included), or null on a box without
  # one. Deliberately NOT named `postgresql`: callPackage would then fill it
  # in from nixpkgs on every box, and with whatever version nixpkgs calls
  # default rather than the one the server runs.
, postgresqlPackage ? null
}:

# Wraps keisi-deploy.sh with its runtime deps on PATH. Installed into the box's
# system packages by modules/apps.nix; the `deploy` user runs it via sudo.
writeShellApplication {
  name = "keisi-deploy";
  runtimeInputs = [ sqlite curl coreutils systemd ]
    # psql + pg_dump for the pre-swap snapshot of a PostgreSQL app, and
    # runuser to run them as the postgres superuser.
    ++ lib.optionals (postgresqlPackage != null) [ postgresqlPackage util-linux ];
  text = builtins.readFile ./keisi-deploy.sh;
}
