# CLOG — VPS Deploy / Update Runbook

Target: the existing production VPS (DigitalOcean, Ubuntu 24.04, `clog.run`).
This does NOT change the existing infrastructure — systemd stays systemd,
Nginx stays Nginx, no Docker/PM2/Kubernetes migration. This is the minimal
repeatable command sequence for shipping a new frontend build.

## Prerequisites (already true on this VPS, not set up by this doc)

- `/opt/clogged` is a git clone of `zaratustrastar/clogged`, `main` branch
- `clog.service` (systemd) runs `npm start` from `/opt/clogged`, port 3000
- Nginx already proxies `https://clog.run` → `http://127.0.0.1:3000`
- `/opt/clogged/.env.production` exists with real values (see `.env.production.example`
  in this repo for the authoritative list — **never commit this file**)
- PostgreSQL 16 is running locally (`clog` database, `clogapp` role)
- Node 22.23.2, 4 GB swap (the production build needs more than 2 GB
  physical RAM without it)

## Standard update sequence

```bash
cd /opt/clogged
git pull origin main

# npm ci is preferred when package-lock.json changed (exact, reproducible
# install); npm install is fine otherwise. When in doubt, npm ci is safer.
npm ci

# See the database migration section below - run this whenever
# lib/db/migrations/ has a new file, harmless (skips already-applied ones)
# otherwise.
npm run migrate

# Rebuild - REQUIRED after any change to code OR any NEXT_PUBLIC_* value in
# .env.production (see that file's own header comment for why a restart
# alone is never sufficient for NEXT_PUBLIC_* changes).
npm run build

# Ownership only needs fixing if git pull or npm ci ran as a different user
# than the service - adjust <user> to whichever account actually owns
# clog.service's working directory.
# sudo chown -R <user>:<user> /opt/clogged

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
- Creating the Postgres database/role, R2 bucket, or Reown project — these
  are one-time setup steps, not part of the repeatable update sequence (see
  the operator handoff document for what to create once).
- Nginx/TLS configuration changes — already working, out of scope unless it
  actually breaks.
