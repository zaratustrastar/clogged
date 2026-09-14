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

Covers both code changes and deployment-manifest changes (see
`docs/DEPLOYMENTS.md` — switching which contracts `clog.run` points at is
now just an edit to `deployments/robinhood-mainnet.json`, committed like any
other code change, picked up by this exact same `git pull` + build +
restart sequence):

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
curl -s https://clog.run/api/ticker-metadata/1 # 404 until token 1 is actually launched
curl -sI https://clog.run/uploads/ | head -5   # 403/404 expected (no index, no such path) - confirms Nginx is serving this location at all
```

## Rollback

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
