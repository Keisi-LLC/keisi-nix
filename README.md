# keisi-nix — managed Go app boxes + a git-push workflow

The reusable half of the deploy story. NixOS defines the **boxes**
declaratively; a tiny deploy tool (`keisi-deploy`) ships **app binaries** onto
them. One shared box serves every dev/staging app at `<app>.keisi.co`;
dedicated boxes serve promoted apps at their own TLD. Adding an app needs **no
box rebuild**.

> **Status:** target-state, **not yet piloted** — no `nix flake check` on a
> real box. Review-grade; `TODO(you)` marks every value only you know. This
> **supersedes the earlier `deploy-rs`/per-project-flake scaffold** — that was
> heavier than the seamless-many-apps workflow we landed on. The invariants it
> kept: one CGO-free static binary, hardened systemd unit, loopback/socket
> behind Caddy, `/healthz`-gated deploy with rollback, Litestream for SQLite.

Should become its **own repo** (`github:<owner>/keisi-nix`) so app/infra repos
can pin it. Lives here only as the authoring home.

## The pieces

| Output | What it is |
|---|---|
| `nixosModules.base` | box baseline: ssh hardening, firewall, `deploy` sudoer, gc, sops age identity |
| `nixosModules.apps` | `services.keisi` — the templated `app@` unit + Caddy routing + `keisi-deploy`, and opt-in PostgreSQL with backups (`services.keisi.postgres`) |
| `lib.mkHost { system; hostName; modules; }` | a `nixosSystem` = base + apps + sops |
| `packages.<sys>.keisi-deploy` | the on-box deploy tool |
| `templates.app` | `nix flake init -t …#app` — a Go app repo's deploy layer (no per-repo Nix) |
| `templates.infra` | `…#infra` — the box fleet (shared keisi.co + a prod host example) |

## How a deploy works

```
app repo: git push main ─► CI builds CGO-free binary ─► scp to box:/tmp
                                                          └─ ssh: sudo keisi-deploy <app> /tmp/<app>.bin
keisi-deploy on the box:  timestamped release ─► pre-swap sqlite .backup (or pg_dump) ─► flip `current`
                       symlink ─► restart app@<app> ─► poll /healthz over the socket
                       ─► auto-rollback on failure ─► prune
Caddy:  *.keisi.co ─► reverse_proxy unix//run/apps/{subdomain}/app.sock   (no per-app config)
```

Boxes themselves change rarely; when they do:
`nixos-rebuild switch --flake .#keisi --target-host deploy@<ip> --elevate=sudo`.

## The on-box contract (what `apps.nix` and `keisi-deploy` agree on)

```
/opt/apps/<app>/current            symlink → live release binary
/var/lib/apps/<app>/<app>.db       SQLite DB (+ backups/)
PostgreSQL database <app>          instead, for apps in services.keisi.postgres.databases
/var/lib/apps/<app>/backups/       pre-swap snapshots: <app>-<ts>.db or <app>-<ts>.dump
/run/apps/<app>/app.sock           the socket Caddy proxies to
/etc/apps/<app>.env                optional secrets (EnvironmentFile)
app@<app>.service                  the per-app unit (from one template)
```

Injected env: `APP_ADDR` (the socket), `APP_DB`, `APP_ENV` (`staging`|`prod`),
`APP_TRUSTED_PROXY=true`. Apps listen on `APP_ADDR` (unix when it's a path).
An app listed in `services.keisi.postgres.databases` also gets
`APP_DATABASE_URL` — see below.

## Shared vs dedicated box

```nix
# shared dev/staging (keisi.co): wildcard cert + subdomain-to-socket routing
services.keisi = { enable = true; env = "staging"; wildcardDomain = "keisi.co"; dnsProvider = "cloudflare"; };

# dedicated prod: a normal auto-TLS vhost per real domain
services.keisi = { enable = true; env = "prod"; domains.kirkpatrick = "kirkpatrick.app"; };
```

## PostgreSQL (opt-in, per app)

SQLite stays the default. An app that has outgrown it is listed, and the box
grows a PostgreSQL 17 server for it — on the same box, reached over the unix
socket, with no password and no TCP listener:

```nix
services.keisi.postgres.databases = [ "kirkpatrick" ];
```

For each name this creates a database and an owning role of that name (not a
superuser), lets the shared `apps` OS user log in as that role and no other
(peer authentication through an ident map), and gives `app@<name>`:

```
APP_DATABASE_URL=postgres:///<name>?host=/run/postgresql&user=<name>
```

so the app needs no secret to find its database. That variable, and an
ordering after PostgreSQL, arrive in a per-instance drop-in
(`app@<name>.service.d/`). The shared `app@` template is not touched, so
unlisted apps keep their exact unit and are not restarted — SQLite and
PostgreSQL apps can share a box.

| Option (`services.keisi.postgres.…`) | Default | |
|---|---|---|
| `databases` | `[ ]` | apps on PostgreSQL; empty = no PostgreSQL at all |
| `package` | `pkgs.postgresql_17` | pinned here, not left to `system.stateVersion` |
| `initdbArgs` | UTF-8, builtin `C.UTF-8` collation, data checksums | applied once, at cluster creation — text sorts by code point, as in SQLite, and does not depend on glibc |
| `sharedBuffers` | `256MB` | memory settings assume a 2 GB box that also runs the app |
| `effectiveCacheSize` | `768MB` | planner hint; allocates nothing |
| `workMem` | `8MB` | per sort/hash step, per connection |
| `maintenanceWorkMem` | `64MB` | VACUUM, CREATE INDEX |
| `maxConnections` | `40` | |

`keisi-deploy` takes its pre-swap snapshot of such an app with `pg_dump -Fc`
into `/var/lib/apps/<app>/backups/<app>-<ts>.dump`, pruned like the SQLite
ones. A failed dump is a loud warning, not a failed deploy — the same contract
as the SQLite snapshot.

### Backups (`services.keisi.postgres.backup`)

The handbook's two mechanisms, for PostgreSQL:

- **pgBackRest → an S3-compatible bucket (R2).** A full backup weekly, a
  differential nightly, and every WAL segment as it closes (`archiveTimeout`,
  60 s — the exposure if the box is lost). Restores to any moment in the last
  `retentionDays` (14). The stanza is created, and a first full backup taken,
  on first boot — no manual step.
- **Nightly `pg_dump -Fc`**, `dump.keepDays` (14) days, in
  `/var/backups/<app>/<date>/<app>.dump` on local disk.

```nix
services.keisi.postgres.backup = {
  enable = true;
  s3.endpoint = "<account-id>.r2.cloudflarestorage.com";
  s3.bucket = "kirkpatrick-prod-backups"; # one bucket per box
  environmentFile = config.sops.secrets."pgbackrest-env".path;
  check.pingUrlFile = config.sops.secrets."backup-ping-url".path;
};
sops.secrets."pgbackrest-env".restartUnits = [ "postgresql.service" ];
```

`environmentFile` holds the bucket credentials as pgBackRest's own variables
— `PGBACKREST_REPO1_S3_KEY=…` and `PGBACKREST_REPO1_S3_KEY_SECRET=…`, plain
`NAME=value` lines. PostgreSQL reads it once, at start (archive_command runs
inside it), hence the `restartUnits`.

| Option (`…backup.…`) | Default | |
|---|---|---|
| `s3.endpoint`, `s3.bucket` | — | required |
| `s3.region` | `auto` | R2's region |
| `s3.uriStyle` | `path` | `https://<endpoint>/<bucket>/…` |
| `s3.path` | `/pgbackrest` | prefix inside the bucket |
| `environmentFile` | — | required; a sops secret, never the store |
| `fullSchedule` / `diffSchedule` | Sun 02:30 / Mon–Sat 02:30 | |
| `retentionDays` | `14` | how far back a point-in-time restore always reaches |
| `archiveTimeout` | `60` | seconds |
| `dump.schedule` / `dump.directory` / `dump.keepDays` | 03:30 / `/var/backups` / `14` | |
| `check.schedule` | `*:0/15` | |
| `check.maxBackupAgeHours` / `check.maxDumpAgeHours` | `30` / `30` | |
| `check.maxPendingWal` | `8` | WAL segments waiting to be archived |
| `check.maxDiskUsedPercent` | `80` | data volume and dump volume |
| `check.pingUrl` / `check.pingUrlFile` | — | healthchecks-style URL; prefer the file |

**The check is the point.** `keisi-pg-backup-check` runs every 15 minutes and
fails its unit when the newest backup or dump is too old, when PostgreSQL's
last WAL archive attempt failed or segments are queueing (a failing
archive_command does not stop the database — it fills the disk, and *then* the
database stops), when the stanza is not healthy, or when the disk is filling.
Anything it cannot determine counts as a failure. With a ping URL it pings on
success and `<url>/fail` on failure, so a dead box or a stopped timer raises
the alarm by going quiet.

What is on the box:

```
postgresql.service                  the server; archive_command = pgbackrest archive-push
keisi-pg-stanza.service             first boot: stanza-create, then a first full backup
pgbackrest-default-{full,diff}      the backup jobs (.timer + .service, from nixpkgs)
keisi-pg-dump                       nightly pg_dump (.timer + .service)
keisi-pg-backup-check               the check (.timer + .service)
sudo keisi-pgbackrest <args>        pgBackRest by hand, with the credentials loaded:
                                      sudo keisi-pgbackrest info
                                      sudo keisi-pgbackrest --postgres … restore
```

Nothing here is a daemon holding stale configuration: pgBackRest re-reads
`/etc/pgbackrest/pgbackrest.conf` on every invocation, and any change to
PostgreSQL's settings changes `postgresql.service` itself, so `nixos-rebuild`
restarts it.

Not yet proven against a real bucket — see the PR that added this for the
list of assumptions to test first.

Secrets are sops-nix (see `../ENV-VARS.md`); dev apps usually need none
(graceful degradation). Local dev is unchanged: `op run --environment <Dev>`.
Full workflow + promotion: `../GITOPS.md`.
