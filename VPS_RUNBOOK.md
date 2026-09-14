# CLOG — VPS Deploy / Update Runbook

Target: the existing production VPS (DigitalOcean, Ubuntu 24.04, `clog.run`).
This does NOT change the existing infrastructure — systemd stays systemd,
Nginx stays Nginx, no Docker/PM2/Kubernetes migration. This is the minimal
repeatable command sequence for shipping a new frontend build.

## Prerequisites (already true on this VPS, not set up by this doc)

- `/opt/clogged` is a git clone of `zaratustrastar/clogged`, `main` branch
- `clog.service` (systemd) runs `npm start` from `/opt/clogged` as
  `User=clog Group=clog`, port 3000
- Nginx already proxies `https://clog.run` → `http://127.0.0.1:3000`
- `/opt/clogged/.env.production` exists with real values (see `.env.production.example`
  in this repo for the authoritative list — **never commit this file**)
- PostgreSQL 16 is running locally (`clog` database, `clogapp` role)
- Node 22.23.2 (`--env-file` verified working on Node 22.22.2 in this
  session — a stable flag since Node 20.6, unaffected by the 22.22→22.23
  patch difference), 4 GB swap (the production build needs more than 2 GB
  physical RAM without it)

## `.env.production` permissions (one-time setup, not part of every deploy)

`clog.service` runs as `User=clog Group=clog`, so the `clog` account needs
read access to this file — and since it holds `DATABASE_URL` credentials,
nothing else should be able to read it:

```bash
sudo chown clog:clog /opt/clogged/.env.production
sudo chmod 600 /opt/clogged/.env.production
```

With those permissions, only the `clog` user (or root) can read the file —
so the two commands below that actually need it (the migration script, and
the build, which Next.js's own env-file loading reads automatically) must
run as `clog`. `git pull`/`npm ci`/`systemctl restart` don't touch this file
and can keep running as whichever account you already use for deploys.

If `npm run build` as `clog` hits a permission error writing to
`node_modules/`/`.next/`, it means `/opt/clogged` isn't writable by `clog` —
either run `npm ci` as `clog` too (simplest: `sudo chown -R clog:clog
/opt/clogged` once, then run the whole sequence as `clog`), or adjust group
permissions so `clog` can write there without owning the whole tree. Which
is right depends on how the checkout was originally set up on this specific
VPS, which I can't see from here.

## Upload directory setup (one-time, before the first real launch)

Uploaded meme images live at `/var/lib/clog/uploads` — deliberately outside
`/opt/clogged`, so they survive every future `git pull`/redeploy untouched.
`clog` (the app) needs to create files there; Nginx needs to read them
directly, without every image request round-tripping through Next.js.

```bash
sudo mkdir -p /var/lib/clog/uploads
sudo chown clog:clog /var/lib/clog/uploads
sudo chmod 755 /var/lib/clog/uploads
```

Mode `755`: only `clog` (the owner) can create/write files here — never
world-writable. Read+traverse is left open to everyone, which is
appropriate for images that are already served publicly over HTTPS to
anyone who asks; this also sidesteps having to know or configure exactly
which user Nginx's worker process runs as (`www-data` on stock Ubuntu, but
that's not guaranteed) — no group-membership juggling required. Files the
app writes inherit Node's own default write mode (typically `644` under a
standard `022` umask), which is already group/other-readable, so Nginx can
read them as soon as it can traverse the directory.

Add this `location` block inside the existing `server { ... }` block for
`clog.run` in your Nginx site config, **above** the existing
`location / { proxy_pass http://127.0.0.1:3000; ... }` block (Nginx matches
the most specific applicable `location`, but placing it first keeps intent
obvious):

```nginx
location /uploads/ {
    alias /var/lib/clog/uploads/;   # trailing slash on both sides - required for alias to resolve correctly
    autoindex off;                   # no directory listing

    # Filenames are random UUIDs, never reused - safe to cache forever.
    add_header Cache-Control "public, max-age=31536000, immutable";

    # Defense in depth: uploaded files are always validated PNG/JPEG/WEBP/GIF
    # by the application before they ever land here, so nothing executable
    # should ever exist in this directory - but refuse to execute anything
    # that looks like a script regardless, rather than relying solely on
    # that upstream validation.
    location ~ \.(php|phtml|cgi|pl|py|sh)$ {
        deny all;
    }
}
```

This exposes only `/var/lib/clog/uploads/` at `/uploads/` — `alias` maps
exactly that path, nothing broader from `/var/lib/clog/` leaks out.

```bash
sudo nginx -t                 # validate the config before touching anything live
sudo systemctl reload nginx   # zero-downtime reload, not a restart
```

Test end to end with a throwaway file, then clean up:

```bash
echo "clog upload test" | sudo -u clog tee /var/lib/clog/uploads/test.txt > /dev/null
curl -sI https://clog.run/uploads/test.txt | head -5   # expect 200
sudo rm /var/lib/clog/uploads/test.txt
curl -sI https://clog.run/uploads/test.txt | head -5   # expect 404 now
```

## Standard update sequence

Covers ordinary code changes and deployment-manifest changes that do NOT
include a breaking DB schema migration (see `docs/DEPLOYMENTS.md` —
switching which contracts `clog.run` points at is normally just an edit to
`deployments/robinhood-mainnet.json`, committed like any other code
change, picked up by this exact same `git pull` + build + restart
sequence). **If the update includes a migration that changes an existing
table's columns/constraints in a way the currently-running old code
doesn't write compatibly with (exactly the case for migration 002 - see
"Deployments with a breaking DB migration" below), do NOT use this
sequence** - `migrate` running before `restart` leaves the old app
running against the new, incompatible schema for the entire build
window, and its own writes will start failing immediately once the
migration completes, not just risk failing:

```bash
cd /opt/clogged
git pull origin main

# npm ci is preferred when package-lock.json changed (exact, reproducible
# install); npm install is fine otherwise. When in doubt, npm ci is safer.
npm ci

# scripts/migrate.mjs reads process.env.DATABASE_URL directly - it does NOT
# load .env.production itself (unlike npm run build/start, which get it
# automatically via Next.js's own env-file loading). --env-file is a stable
# Node flag since 20.6, verified working here on Node 22.22.2. Run whenever
# lib/db/migrations/ has a new file - harmless (skips already-applied ones)
# otherwise. Do NOT run this as `npm run migrate` on the VPS - that script
# has no --env-file and will silently see an empty DATABASE_URL unless
# you've separately exported it into the shell. Runs as `clog` because
# .env.production is now 600 clog:clog - adjust the sudo user below if your
# actual account setup differs.
sudo -u clog node --env-file=.env.production scripts/migrate.mjs

# Rebuild - REQUIRED after any change to code OR any NEXT_PUBLIC_* value in
# .env.production (see that file's own header comment for why a restart
# alone is never sufficient for NEXT_PUBLIC_* changes). Also needs to read
# .env.production (Next.js loads it automatically at build time), so this
# runs as `clog` too.
sudo -u clog npm run build

sudo systemctl restart clog
sudo systemctl status clog
```

## Deployments with a breaking DB migration (this canary rollout)

`lib/db/migrations/002_deployment_scoped_token_profiles.sql` makes
`chain_id`/`ticker_registry_address` `NOT NULL` and replaces
`token_profiles`'s primary key with a composite one. The currently-running
old app's own `INSERT ... ON CONFLICT (token_id) DO UPDATE` (see
`lib/metadata/PostgresTokenProfileStore.ts` on `main`) never sets those
two columns and targets `ON CONFLICT (token_id)` specifically - once this
migration is applied, that statement fails outright (`null value in
column "chain_id" violates not-null constraint`, and separately, `there is
no unique or exclusion constraint matching the ON CONFLICT specification`,
since `token_id` alone is no longer a unique constraint after the PK
change). This is a hard failure the instant the migration completes, not
a mere compatibility risk - so `migrate` must never run while the old app
is still serving traffic.

**This sequence favors correctness over zero downtime, on purpose.** An
earlier version of this runbook built the new app while the old app was
still running, on the theory that a build only writes files and doesn't
touch the schema. That's true of the schema, but not of `.next/` itself:
a running Next.js production server can still read server chunks and
static build artifacts from `.next/` at request time, and rebuilding that
same directory underneath a live process can produce transient missing
or mismatched artifacts - a real risk, not merely a theoretical one. This
rollout accepts a short, controlled maintenance window instead: the app
is stopped BEFORE the build even starts, not just before the migration.
No symlink/release-directory (e.g. blue-green, `current` → timestamped
release dirs) architecture is introduced to avoid this - that's more
machinery than a canary rollout needs; a few minutes of downtime, done in
the right order, is the simpler and safer choice here.

**Sequence - backup while healthy, pull source only, then a single stop/build/migrate/start window:**

```bash
cd /opt/clogged

# 1. Back up the DB while the OLD app is still healthy and serving -
#    this touches only Postgres, never the app or its files, so it's
#    safe to do before anything else. Runs as the `postgres` superuser,
#    not the `clog` Unix user - there is no guarantee the `clog` Unix
#    account can authenticate as a matching Postgres role, and
#    `postgres` can always read/dump any local database regardless.
sudo -u postgres pg_dump -Fc clog > /var/backups/clog-pre-migration-002-$(date +%Y%m%d%H%M%S).dump
sudo -u postgres psql -d clog -c "SELECT count(*) FROM token_profiles;"   # read-only sanity check

# 2. Pull new source only - do NOT build yet. The old compiled app
#    (.next/ from its own prior build) keeps serving correctly: Node
#    already has the old code loaded in memory, and overwriting source
#    files on disk does not affect a process that already started, or
#    the .next/ directory it's currently reading from.
git pull origin main
# package.json/package-lock.json did not change in this rollout's diff,
# so npm ci is unnecessary here - included only for completeness if a
# future rollout's diff does change dependencies:
# npm ci

# 3. Begin controlled downtime. Stop the OLD app before building the NEW
#    one - not after. This is the actual fix: a build must never run
#    while a live process is still reading .next/ out from underneath it.
sudo systemctl stop clog

# 4. Build the NEW app now that nothing is reading the old .next/ anymore.
sudo -u clog npm run build
# CHECK THE EXIT CODE before doing anything else:
echo "build exit code: $?"

# 5. Only if step 4 succeeded: run the migration - see below if it didn't.
sudo -u clog node --env-file=.env.production scripts/migrate.mjs
echo "migration exit code: $?"

# 6. Only if step 5 succeeded: start the app.
sudo systemctl start clog
sudo systemctl status clog --no-pager

# 7. Health + metadata smoke tests - see below.
```

**Failure ordering - three distinct points, three distinct recoveries:**

**If the build (step 4) fails:** the DB has not been touched at all - the
migration hasn't run yet. Do NOT migrate. Recovery:
1. Inspect the build's own error output.
2. If fixable quickly (a config issue, a missed dependency), fix and
   re-run step 4.
3. If serving traffic again matters more than finishing this rollout
   right now: recover the previous source and build, then restart the
   old app - `git checkout <previous known-good commit>` (whatever `main`
   pointed at before step 2's pull), `npm ci` (only if needed),
   `sudo -u clog npm run build`, `sudo systemctl start clog`. A full
   rebuild is required - there is no shortcut once the working tree has
   moved past the old commit, and the failed build may have left `.next/`
   in a partial, inconsistent state that a plain restart can't recover
   from on its own.

**If the migration (step 5) fails:** `scripts/migrate.mjs` runs every
migration file inside its own `BEGIN`/`COMMIT`, with an explicit
`ROLLBACK` in its `catch` block before re-throwing (confirmed directly
against the script's own source, not assumed) - a failure partway through
migration 002's SQL is automatically rolled back by Postgres itself. The
normal recovery state is already the old schema; there is nothing to
manually reverse as the first response. Do NOT start the new app until
this is resolved - the newly-built app's own queries expect the NEW
schema (the composite key, the two new columns), so starting it against
a rolled-back OLD schema would just trade one hard failure for another.
Recovery:
1. Inspect the actual error from `scripts/migrate.mjs`'s own output - the
   transaction is already gone, so this is purely diagnostic.
2. Confirm the schema is genuinely still the old one:
   `sudo -u postgres psql -d clog -c "\d token_profiles"` should show the
   original single-column `token_id` primary key, with no `chain_id`/
   `ticker_registry_address` columns.
3. If the migration is safe to retry (e.g. a transient DB connection
   issue, not a real schema conflict), fix the cause and re-run step 5 -
   the app is already stopped and the new build is already in place, so
   this is just re-running one command.
4. If serving traffic again before a fix is ready matters more than
   completing this rollout right now: the schema is already back to old
   (per step 2's confirmation above), so bring the OLD app/OLD schema
   back into sync together - `git checkout <previous known-good commit>`,
   `npm ci` (only if needed), `sudo -u clog npm run build`,
   `sudo systemctl start clog`. Do not start the already-built NEW app
   against the rolled-back OLD schema; its own queries are not
   compatible with it either.

**If the app fails to start (step 6) after a SUCCESSFUL migration:** the
schema is now the new schema, and the new app's own code is what's
compatible with it - rolling back to the OLD app code without also
reverting the migration would immediately hit the exact same failure
this whole procedure exists to avoid. Recovery:
1. Check `sudo systemctl status clog` and `sudo journalctl -u clog -n 100`
   for the real startup error.
2. Prefer fixing forward (the new code is correct for the new schema;
   most startup failures here are config issues - a missing/wrong env
   var, a permissions problem - not the migration itself).
3. Only if a full DB rollback is truly necessary: **prefer restoring the
   step-1 pre-migration dump** (`pg_restore -d clog --clean
   /var/backups/clog-pre-migration-002-<timestamp>.dump`, as `postgres`)
   over manually reversing the schema with SQL. A simple "drop the new
   columns, restore `PRIMARY KEY (token_id)`" is NOT universally safe to
   present as a first option here: if the canary deployment has been live
   even briefly, real deployment-scoped rows may already exist - a HOOD
   profile and a canary profile can legitimately share the same
   `token_id` (e.g. both have their own tokenId 1) once the composite key
   is what's keeping them apart. Collapsing back to a bare `token_id`
   primary key at that point can fail outright (a duplicate-key
   violation) or silently keep only one of two real, distinct rows -
   restoring the dump avoids this entirely, since it recreates the exact
   pre-migration data, not a schema hand-reversal that assumes no new
   rows were ever written under the new key shape. Once the DB is back to
   its pre-migration state (dump restored), bring the code back in sync
   with it too: checkout the old commit, rebuild, and start the old app -
   restoring the DB alone while the new app stays running would put the
   new code in front of the old schema, the exact mismatch this whole
   procedure exists to prevent.

## Health verification

```bash
curl -s https://clog.run/api/health | python3 -m json.tool
```

Expect `{"status": "ok", "database": "connected", "timestamp": "..."}`. A
`database` value of `"not_configured"` or `"error"` means `DATABASE_URL` in
`.env.production` is missing or unreachable — check that before assuming the
whole deploy failed, since the app itself can still be serving pages fine
with the database down (only Postgres-backed features degrade).

Also worth a quick manual check after any real config change:

```bash
curl -sI https://clog.run/ | head -5          # 200, real headers
curl -s https://clog.run/api/ticker-metadata/1 # legacy HOOD (tokenId 1 = HOOD, already launched) - expect real metadata, NOT 404
curl -sI https://clog.run/uploads/ | head -5   # 403/404 expected (no index, no such path) - confirms Nginx is serving this location at all
```

**Smoke tests specific to this canary rollout** (run these after any
deployment that includes migration 002 and points the manifest at the
canary deployment):

```bash
# 1. Basic health
curl -s https://clog.run/api/health | python3 -m json.tool
# expect {"status": "ok", "database": "connected", ...}

# 2. Legacy HOOD metadata - permanently bound to LEGACY_HOOD_DEPLOYMENT,
#    unaffected by which deployment the manifest's active config points
#    at. tokenId 1 = HOOD, already launched - expect real metadata, NOT 404.
curl -s https://clog.run/api/ticker-metadata/1 | python3 -m json.tool
# expect: "name": "$HOOD — CLOG Ticker" (or similar), NOT an error object

# 3. Canary metadata - canary tokenId 1 = CNRYA, already launched on the
#    verified deployment. Resolves via getKnownDeploymentById("canary-v1"),
#    which derives from the manifest - expect real metadata, NOT 404.
curl -s https://clog.run/api/ticker-metadata/canary-v1/1 | python3 -m json.tool
# expect: "name": "$CNRYA — CLOG Ticker" (or similar), attributes include
# {"trait_type": "Deployment", "value": "canary-v1"}, NOT an error object

# 4. Canary artwork - same tokenId, deployment-scoped image route
curl -sI https://clog.run/api/ticker-image/canary-v1/1 | head -5
# expect: 200, Content-Type: image/svg+xml
```

If any of tests 2-4 returns 404 or an error object where real metadata is
expected, do not assume the rollout is broken before checking: (a) did
migration 002 actually run and succeed (test 1's `database: "connected"`
only confirms connectivity, not that this specific migration applied -
`psql -c "\d token_profiles"` to confirm the composite primary key
exists), and (b) does `deployments/robinhood-mainnet.json` on the running
commit actually have the real, non-placeholder canary TickerRegistry
address (it does as of this rollout's own commit - this check is for
future deployments that might reuse this runbook section).

## Rollback

**If this deployment included migration 002 (or any other breaking
schema change), the generic rollback below is NOT sufficient by itself**
— reverting the app code without also reverting the DB schema leaves the
old code running against a schema its own queries are incompatible with,
which is the exact failure mode the "Deployments with a breaking DB
migration" section above exists to prevent. Use that section's own
rollback procedure instead when a schema migration is involved.

```bash
cd /opt/clogged
git log --oneline -5          # find the last known-good commit
git checkout <previous-sha>
npm ci
npm run build
sudo systemctl restart clog
```

Return to `main` with `git checkout main` once a fix is ready.

## Logs

```bash
sudo journalctl -u clog -f              # live tail
sudo journalctl -u clog --since "1 hour ago"
sudo systemctl status clog              # quick health snapshot + recent log lines
```

## What this runbook deliberately does NOT cover

- Blockchain contract deployment/broadcast — see `contracts/DEPLOY_MAINNET.md`.
  No deployment private key or signer credential belongs anywhere in
  `/opt/clogged` or this frontend's own environment.
- Creating the Postgres database/role, the upload directory (see above -
  this doc *does* cover it, just not as part of the repeatable update
  sequence), or Reown project — one-time setup steps.
- Nginx/TLS configuration changes — already working, out of scope unless it
  actually breaks.
