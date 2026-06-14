# SEHC AI Gateway — Deployment Runbook

Kong OSS 3.9 · nginx auth proxy · User Management Portal

---

## Pre-Upgrade Checklist

Before every upgrade, confirm all five:

- [ ] A recent backup of `./data/` exists (upgrade.sh creates one automatically).
- [ ] You have reviewed `git log HEAD..origin/master --oneline` and understand what's changing.
- [ ] You are in a maintenance window (user sessions will briefly drop during container restarts).
- [ ] `docker compose ps` shows all services healthy before you start.
- [ ] You have the admin password stored somewhere safe (not in your terminal history).

---

## First Install (air-gapped / with image tarballs)

### Prerequisites

- Docker + Docker Compose v2 on the target host.
- The release tarball: `kong-deploy-v<VERSION>.tar.gz`.
- Kong base images (`kong:3.9`, `postgres:15-alpine`, `nginx:alpine`) already loaded into Docker. These come from the original `kong-offline-package.tar.gz` and are NOT re-shipped in each release — they are stable across versions.
- The `kong-usermgmt` image **is** bundled inside the release tarball at `images/kong-usermgmt.tar`; `deploy.sh` loads it automatically. No internet build required.

### Steps

```bash
# 1. Copy the release tarball to the PCA box, then:
tar xzf kong-deploy-v1.0.1.tar.gz
cd kong-deploy-v1.0.1/

# 2. Run the install script
chmod +x deploy.sh
./deploy.sh
```

`deploy.sh` will:

1. Load the bundled `images/kong-usermgmt.tar` into Docker (single image, ~25 MB).
2. Generate `.env` with random `SESSION_SECRET` and `KONG_PG_PASSWORD`.
3. Prompt for an SMTP relay hostname (or accept the default `mail.internal`).
4. Prompt for an admin password (auto-generates one if left blank).
5. Create `nginx/.htpasswd` for the `kong` admin user. If the host lacks the `htpasswd` binary, the just-loaded `kong-usermgmt:latest` image is used as a fallback (no internet pull).
6. Skip `docker compose build` because the pre-built image is already loaded.
7. Start the full stack with `docker compose up -d`.
8. Wait for `kong-usermgmt /healthz`.
9. Print the admin password and access URLs.

**Save the printed admin password — it is shown once.**

### Post-install

- Kong Manager GUI:  `http://<host>:8002/`  (admin-only since v1.0.3)
- User Mgmt Portal:  `http://<host>:8888/`
- Kong Proxy (HTTP): `http://<host>:8000/`
- Kong Proxy (HTTPS):`https://<host>:8443/` (self-signed IP cert, auto-generated)
- Metrics (Status API): `http://<host>:8100/metrics`

Configure SMTP via the **SMTP Settings** card in the User Mgmt Portal if you skipped it during install.

### Monitoring

Metrics and the Prometheus plugin are enabled automatically by the deploy script.
To wire Zabbix + Grafana (or the self-contained Prometheus/Loki/Grafana stack) and
alerting, see **[MONITORING.md](MONITORING.md)**.

---

## Upgrade

### Air-gapped / PCA upgrade — one-shot script (recommended for production)

Copy three files to the PCA box (USB, file share, jumpbox — whatever your transfer mechanism is):

```
kong-deploy-vX.Y.Z.tar.gz
kong-deploy-vX.Y.Z.sha256.txt
pca-deploy.sh
```

Then run a single command on PCA:

```bash
sudo ./pca-deploy.sh kong-deploy-vX.Y.Z.tar.gz
```

That's it. The script handles everything:

1. Verifies the tarball SHA256.
2. Auto-detects the existing Kong install directory (`docker inspect kong`).
3. Snapshots config + Postgres data to `<install>/backups/pre-upgrade-<UTC>/`.
4. Extracts the new bundle (preserving `.env`, `nginx/.htpasswd`).
5. Creates `.env` with `KONG_PG_PASSWORD=kong_pass` if missing (the v1.0.0→v1.0.1 migration).
6. Runs `upgrade.sh --tarball-only` under the hood.
7. Health-checks the result and prints next-step guidance.

If anything goes wrong:

```bash
sudo ./pca-deploy.sh --rollback
```

restores the latest backup (config + .env + Postgres volume).

### Manual upgrade — if you don't want the wrapper

If you prefer to drive each step yourself, this is what `pca-deploy.sh` is doing:

```bash
# 1. Copy the new release tarball to the PCA box, then:
cd /opt/kong          # or wherever the current install lives

# 2. Overwrite code files from the new tarball (data/ and .env are excluded)
tar xzf /tmp/kong-deploy-v1.0.1.tar.gz --strip-components=1

# 3. Run upgrade in tarball-only mode (no git required)
chmod +x upgrade.sh
./upgrade.sh --tarball-only
```

`upgrade.sh --tarball-only` will:

1. Snapshot `./data/` to `./backups/<UTC-timestamp>/data.tar.gz`.
2. Load `images/kong-usermgmt.tar` if present (pre-built at release time — no internet needed).
3. Force-recreate `kong-usermgmt` and restart `kong-auth-proxy`.
4. Run `docker compose up -d` to pick up any compose changes.
5. Wait for `/healthz`.
6. Print a summary.

### Git-pull upgrade (DEV / internet-connected environments)

```bash
cd /opt/kong
./upgrade.sh
```

`upgrade.sh` (no flags) will:

1. Snapshot `./data/` to `./backups/<UTC-timestamp>/data.tar.gz`.
2. Guard against uncommitted local changes (exits if any are found).
3. Show incoming commits (`git log HEAD..origin/master`).
4. Ask for confirmation.
5. Pull with `--ff-only` (refuses merge/rebase).
6. Detect which services are affected by changed files and rebuild/restart only those.
7. Wait for `/healthz`.
8. Print a summary of what was rebuilt and where the backup is.

### Confirm the upgrade

```bash
# Health check
curl -sf http://localhost:8888/healthz && echo OK

# Log in to Kong Manager at http://<host>:8002/
# Verify user list is intact at http://<host>:8888/users
```

### Breaking change — KONG_PG_PASSWORD (v1.0.1 upgrade path)

v1.0.1 removes the hardcoded `kong_pass` database password from `docker-compose.yml`
and replaces it with `${KONG_PG_PASSWORD:?must be set}`.

**If upgrading from a pre-v1.0.1 install**, your existing Postgres volume already has
the password `kong_pass`. You must preserve that value — **do not** let deploy.sh
generate a new random password, which would break database connectivity.

Set `KONG_PG_PASSWORD` manually in your `.env` before running upgrade.sh:

```bash
echo 'KONG_PG_PASSWORD=kong_pass' >> .env
```

Then run:

```bash
./upgrade.sh --tarball-only
```

Only change `KONG_PG_PASSWORD` to a new value if you also intend to destroy and
recreate the Postgres volume (`docker compose down -v`), which **destroys all Kong
route/service/plugin data**. Restore from a Kong deck backup if you do this.

---

## Rollback

Use this when an upgrade breaks the service and you need to revert fast.

```bash
# 1. Stop the stack
docker compose down

# 2. Restore data from the backup written by upgrade.sh
BACKUP_TS="20260101T120000Z"   # replace with actual timestamp
tar xzf ./backups/${BACKUP_TS}/data.tar.gz

# 3. Reset code to the previous version tag or commit
git reset --hard <previous-tag-or-sha>

# 4. Rebuild and restart
docker compose build kong-usermgmt
docker compose up -d

# 5. Verify
curl -sf http://localhost:8888/healthz && echo OK
```

---

## What's Preserved Across Upgrades

| Artifact | Location | Preserved? |
|---|---|---|
| Environment secrets | `.env` | Yes — never overwritten by upgrade.sh |
| Admin auth | `nginx/.htpasswd` | Yes — never overwritten |
| User accounts & sessions | `./data/users.json`, `./data/*.json` | Yes — bind-mounted host dir |
| Audit logs | `./data/audit/` | Yes — bind-mounted host dir |
| Postgres data | `kong_pg_data` Docker volume | Yes — Docker managed volume |
| SMTP settings | `./data/smtp.json` | Yes — bind-mounted |

## What Gets Replaced

| Artifact | What happens |
|---|---|
| Python app source | Replaced by new tarball, image rebuilt |
| `nginx/default.conf` | Replaced; `kong-auth-proxy` restarted |
| `nginx/portal.html` | Replaced; `kong-auth-proxy` restarted |
| `docker-compose.yml` | Replaced; `docker compose up -d` re-evaluates |
| Static assets | Replaced inside rebuilt image |

---

## Common Errors and Recovery

### Health check fails after upgrade

```bash
docker compose logs kong-usermgmt
# Look for Python tracebacks, missing env vars, or file permission errors.
docker compose restart kong-usermgmt
```

### Database is down / kong-bootstrap fails

```bash
docker compose logs kong-database
# If the volume is corrupt:
docker compose down -v   # WARNING: destroys postgres data
docker compose up -d
```

Restore Kong routes/services from a Kong deck backup if you have one.

### Port conflict (8000, 8001, 8002, 8888 already in use)

```bash
ss -tlnp | grep -E '800[012]|8888'
# Stop the conflicting process, or edit docker-compose.yml ports before starting.
```

### nginx returns 401 for all requests

```bash
# Verify .htpasswd is readable
ls -l nginx/.htpasswd
docker compose restart kong-auth-proxy
```

### MFA emails not sending

Check SMTP settings via the admin GUI. Verify the relay host is reachable:

```bash
docker exec kong-usermgmt nc -zv "$SMTP_HOST" 587
```

---

## Directory Reference

```
/opt/kong/              ← production install root (DEV: /DATA/kong)
├── .env                ← secrets, auto-generated, never in git
├── deploy.sh           ← first-install
├── upgrade.sh          ← in-place upgrade
├── docker-compose.yml
├── nginx/
│   ├── .htpasswd       ← basic-auth credentials, never in git
│   └── default.conf
├── usermgmt/           ← Python user management app
├── data/               ← runtime state, bind-mounted, never in git
│   ├── users.json
│   ├── audit/
│   └── smtp.json
└── backups/            ← created by upgrade.sh, never in git
    └── 20260101T120000Z/
        └── data.tar.gz
```
