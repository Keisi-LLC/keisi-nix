#!/usr/bin/env bash
# keisi-deploy <app> <new-binary> — receive a built static binary and make it live.
#
# Runs as root on a keisi app box (invoked over ssh: `sudo keisi-deploy <app> /tmp/<app>.bin`).
# The on-box contract (shared by the NixOS `app@` unit and Caddy):
#   /opt/apps/<app>/releases/<ts>/<app>   timestamped releases
#   /opt/apps/<app>/current               symlink → the live release
#   /var/lib/apps/<app>/<app>.db          SQLite DB (+ backups/)
#   PostgreSQL database <app>             instead, for apps listed in
#                                         services.keisi.postgres.databases
#   /run/apps/<app>/app.sock              the unix socket Caddy proxies to
#   /etc/apps/<app>.env                   optional secrets (EnvironmentFile)
#   systemd unit: app@<app>.service       templated, one per app
#
# Mirrors the legacy deploy.sh guarantees: pre-swap online backup, atomic
# symlink flip, health-gate over the socket, automatic rollback, prune.
set -euo pipefail

app="${1:?usage: keisi-deploy <app> <new-binary>}"
src="${2:?usage: keisi-deploy <app> <new-binary>}"
keep="${KEEP_RELEASES:-5}"

base="/opt/apps/$app"
data="/var/lib/apps/$app"
sock="/run/apps/$app/app.sock"

[ -f "$src" ] || { echo "keisi-deploy: no binary at $src" >&2; exit 1; }

ts="$(date +%Y%m%d-%H%M%S)"
rel="$base/releases/$ts"
install -d "$rel"
install -m0755 "$src" "$rel/$app"
rm -f "$src" || true

# Pre-swap snapshot via the online backup API — NEVER cp a live SQLite file.
if [ -f "$data/$app.db" ]; then
  install -d -o apps -g apps "$data/backups"
  sqlite3 "$data/$app.db" ".backup '$data/backups/$app-$ts.db'" || true
  # shellcheck disable=SC2012
  ls -1t "$data/backups"/*.db 2>/dev/null | tail -n +"$((keep + 1))" | xargs -r rm -f
fi

# The same pre-swap snapshot for an app whose database is PostgreSQL. Without
# this branch such an app has no <app>.db, so the block above skips it and it
# deploys with no snapshot at all — and nothing says so.
#
# A database named after the app is the box contract (services.keisi.postgres
# .databases). pg_dump's custom format is consistent while the app is writing
# and restores with pg_restore. Both tools run as the postgres superuser over
# the local socket, because root has no database role of its own; from /, so
# they do not complain about a working directory postgres cannot read.
as_postgres() { (cd / && runuser -u postgres -- "$@"); }

if command -v pg_dump >/dev/null 2>&1; then
  if dbs="$(as_postgres psql -XAtc 'SELECT datname FROM pg_database' postgres 2>/dev/null)"; then
    if grep -qxF -- "$app" <<<"$dbs"; then
      install -d -o apps -g apps "$data/backups"
      dump="$data/backups/$app-$ts.dump"
      # Written under another name and renamed only when complete, so a dump
      # that died halfway never sits in backups/ looking like a good one.
      rm -f "$data/backups"/*.dump.partial
      if as_postgres pg_dump -Fc -d "$app" >"$dump.partial"; then
        mv "$dump.partial" "$dump"
      else
        rm -f "$dump.partial"
        echo "keisi-deploy: WARNING pg_dump of $app failed — deploying WITHOUT a pre-swap snapshot" >&2
      fi
      # shellcheck disable=SC2012
      ls -1t "$data/backups"/*.dump 2>/dev/null | tail -n +"$((keep + 1))" | xargs -r rm -f
    fi
  else
    # PostgreSQL is installed but did not answer, so whether this app has a
    # database is unknown. Say so: staying quiet here is the silent gap.
    echo "keisi-deploy: WARNING could not ask PostgreSQL whether $app has a database — no pre-swap snapshot taken" >&2
  fi
fi

prev="$(readlink "$base/current" 2>/dev/null || true)"
ln -sfn "$rel/$app" "$base/current"

rollback() {
  echo "keisi-deploy: $1 — rolling back" >&2
  if [ -n "$prev" ]; then
    ln -sfn "$prev" "$base/current"
    # A crash-looping bad release trips systemd's start-rate limit within
    # seconds (Restart=always); without reset-failed the restart below would
    # be refused ("start request repeated too quickly") and the app stays down.
    systemctl reset-failed "app@$app" >/dev/null 2>&1 || true
    systemctl restart "app@$app" || true
    # Confirm the rollback actually came back up.
    for _ in $(seq 1 20); do
      if curl -sf --unix-socket "$sock" http://localhost/healthz >/dev/null 2>&1; then
        echo "keisi-deploy: rollback healthy (previous release restored)" >&2
        exit 1
      fi
      sleep 1
    done
    echo "keisi-deploy: WARNING rollback did NOT come healthy — check journalctl -u app@$app" >&2
  fi
  exit 1
}

systemctl reset-failed "app@$app" >/dev/null 2>&1 || true
# The unit's ExecStartPost already health-gates; a failed start returns non-zero.
systemctl restart "app@$app" || rollback "restart/health failed"

# Belt-and-suspenders: confirm /healthz over the socket ourselves.
ok=""
for _ in $(seq 1 20); do
  if curl -sf --unix-socket "$sock" http://localhost/healthz >/dev/null 2>&1; then ok=1; break; fi
  sleep 1
done
[ -n "$ok" ] || rollback "healthz never came up"

# Prune old releases.
# shellcheck disable=SC2012
ls -1dt "$base/releases"/*/ 2>/dev/null | tail -n +"$((keep + 1))" | xargs -r rm -rf

echo "keisi-deploy: $app live @ $ts"
