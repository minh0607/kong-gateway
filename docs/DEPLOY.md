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
- Image tarballs in `offline-package/images/` **inside** the tarball, OR pre-loaded via `docker load`.

### Steps

```bash
# 1. Copy the release tarball to the PCA box, then:
tar xzf kong-deploy-v1.0.0.tar.gz
cd kong-deploy-v1.0.0/

# 2. Run the install script
chmod +x deploy.sh
./deploy.sh
```

`deploy.sh` will:

1. Load any `offline-package/images/*.tar` files into Docker.
2. Generate `.env` with a random `SESSION_SECRET`.
3. Prompt for an SMTP relay hostname (or accept the default `mail.internal`).
4. Prompt for an admin password (auto-generates one if left blank).
5. Create `nginx/.htpasswd` for the `kong` admin user.
6. Build the `kong-usermgmt` image.
7. Start the full stack with `docker compose up -d`.
8. Wait for `kong-usermgmt /healthz`.
9. Print the admin password and access URLs.

**Save the printed admin password — it is shown once.**

### Post-install

- Kong Manager GUI: `http://<host>:8002/`
- User Mgmt Portal: `http://<host>:8888/`
- Kong Proxy:       `http://<host>:8000/`

Configure SMTP via the **SMTP Settings** card in the User Mgmt Portal if you skipped it during install.

---

## Upgrade

### Steps

```bash
# 1. Copy the new release tarball alongside the current project directory
#    and extract, then run upgrade.sh from within the existing working dir:
cd /opt/kong          # or wherever the current install lives

# 2. Overwrite code files from the new tarball (data/ is excluded from tarballs)
tar xzf /tmp/kong-deploy-v1.1.0.tar.gz --strip-components=1

# 3. Run upgrade
chmod +x upgrade.sh
./upgrade.sh
```

`upgrade.sh` will:

1. Snapshot `./data/` to `./backups/<UTC-timestamp>/data.tar.gz`.
2. Show incoming commits (`git log HEAD..origin/master`).
3. Ask for confirmation.
4. Pull with `--ff-only` (refuses merge/rebase).
5. Detect which services are affected by changed files and rebuild/restart only those.
6. Wait for `/healthz`.
7. Print a summary of what was rebuilt and where the backup is.

### Confirm the upgrade

```bash
# Health check
curl -sf http://localhost:8888/healthz && echo OK

# Log in to Kong Manager at http://<host>:8002/
# Verify user list is intact at http://<host>:8888/users
```

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
