# SEHC AI Gateway — Deployment Runbook

Kong OSS 3.9 · PostgreSQL 15 · nginx auth proxy · User Management Portal

This runbook covers installing and upgrading the gateway. For **monitoring**
(Zabbix / Grafana / alerting) see **[MONITORING.md](MONITORING.md)**.

---

## Which script do I use?

| Script | Purpose | Environment |
|---|---|---|
| **`pca-deploy.sh`** | **One-shot install OR upgrade**, auto-detects which. Self-contained, no internet. | **PCA / production (air-gapped)** — recommended |
| `deploy.sh` | First install only (idempotent). | DEV / manual bring-up |
| `upgrade.sh` | Upgrade in place: `--tarball-only` (air-gap) or git-pull (DEV). | DEV, or manual PCA |

> **For production on PCA, use `pca-deploy.sh` and nothing else.** It handles fresh
> installs and upgrades with the same command, generates the proxy TLS cert,
> enables metrics, takes backups, and supports rollback. The other two scripts are
> the DEV-side / manual building blocks.

---

## Production deploy on PCA (air-gapped) — `pca-deploy.sh`

### What to bring

Build the release on DEV (`bash scripts/build-release.sh`), then copy the
**single bundle** (2 files) to PCA via USB / file share / jumpbox:

```
release/kong-pca-bundle-v<X.Y.Z>.tar.gz
release/kong-pca-bundle-v<X.Y.Z>.sha256.txt
```

The bundle is self-contained: release tarball, `pca-deploy.sh`, base image tars
(`kong:3.9`, `postgres:15-alpine`, `nginx:alpine`), the `kong-usermgmt` image,
and docs. No internet or git needed on PCA.

### Run it

```bash
sha256sum -c kong-pca-bundle-v<X.Y.Z>.sha256.txt     # must say OK
tar xzf kong-pca-bundle-v<X.Y.Z>.tar.gz
cd v<X.Y.Z>
sudo ./pca-deploy.sh kong-deploy-v<X.Y.Z>.tar.gz --cert-ip <PCA_IP>
```

`pca-deploy.sh` auto-detects the mode:

- **FRESH** (no `kong` container): creates the install dir (default `/opt/kong`),
  generates `.env` (random `SESSION_SECRET`, `KONG_PG_PASSWORD`), a random admin
  password, and `nginx/.htpasswd`, then brings the whole stack up.
- **UPGRADE** (existing `kong` container): snapshots config + Postgres (`pg_dump`)
  to `<install>/backups/pre-upgrade-<UTC>/`, extracts the new bundle (preserving
  `.env` and `nginx/.htpasswd`), loads the new image, and recreates services.

In both modes it also: generates the **proxy TLS cert** for `:8443` (self-signed,
SAN = `--cert-ip`, auto-detected if omitted), enables the **Prometheus plugin**
(metrics on `:8100`), health-checks, and prints a summary.

| Flag | Meaning |
|---|---|
| `--cert-ip <ip>` | IP clients use to reach `:8443`; sets the TLS cert SAN. Omit → auto-detect (verify on multi-NIC/Docker hosts). |
| `--install-dir <dir>` | Fresh-install target (default `/opt/kong`). |
| `--rollback` | Restore the most recent pre-upgrade backup. |

> **First install only:** the admin password is printed **once** (also written to
> `/opt/kong/.first-install-admin-password.txt`, chmod 600). Save it.

### Verify

```bash
docker compose ps                                           # 4 services Up/healthy
curl -s http://localhost:8002/auth/login | grep 'SEHC AI GATEWAY'
curl -s http://localhost:8100/metrics | grep -c '^kong_'    # > 0
curl -k -s -o /dev/null -w '%{http_code}\n' https://localhost:8443/   # TLS responds
```

### Rollback

```bash
sudo ./pca-deploy.sh --rollback
```

Restores the latest `<install>/backups/pre-upgrade-*/` automatically: config
files, `.env`, and the Postgres volume. You're prompted before anything changes.

---

## DEV / manual

### Fresh install — `deploy.sh`

Run from the project root after extracting a release tarball (or in the dev repo):

```bash
chmod +x deploy.sh
./deploy.sh                       # idempotent; refuses to run over a non-empty ./data/
#   --reset-env        regenerate .env
#   --reset-htpasswd   recreate nginx/.htpasswd
```

It loads the bundled `kong-usermgmt` image, generates `.env` + admin password +
`nginx/.htpasswd`, and starts the stack with `docker compose up -d`.

### Upgrade — `upgrade.sh`

```bash
./upgrade.sh                  # git-pull mode (DEV / internet): fetch, show incoming
                              # commits, confirm, --ff-only pull, rebuild affected svcs
./upgrade.sh --tarball-only   # air-gap: extract new tarball over the install first,
                              # then this rebuilds kong-usermgmt + restarts auth-proxy
```

`upgrade.sh` always snapshots `./data/` to `./backups/<UTC>/data.tar.gz` first and
never touches `.env` or `nginx/.htpasswd`.

---

## Ports

| Port | Service | Exposed to |
|---|---|---|
| `8000` | Kong proxy (HTTP) | API clients |
| `8443` | Kong proxy (HTTPS, self-signed IP cert) | API clients needing TLS |
| `8001` | Kong Admin API (HTTP) | internal |
| `8100` | Status API `/status` + `/metrics` | monitoring host (Zabbix / Prometheus) |
| `8002` | Kong Manager UI (**admin-only** since v1.0.3) | admins |
| `8888` | User Management Portal | admins |

---

## What's preserved across upgrades

| Artifact | Location | Preserved? |
|---|---|---|
| Environment secrets | `.env` | Yes — never overwritten |
| Admin auth | `nginx/.htpasswd` | Yes — never overwritten |
| User accounts, roles, sessions | `./data/users.json`, `./data/*.json` | Yes — bind-mounted |
| Audit logs | `./data/audit/` | Yes — bind-mounted |
| Postgres data (routes/services/plugins/consumers) | `kong_pg_data` volume | Yes — Docker volume |
| SMTP settings | `./data/smtp.json` | Yes — bind-mounted |
| Proxy TLS cert | `./ssl/` | Yes — kept if present; regenerated if absent |
| Prometheus plugin | Postgres | Yes — persists in DB |

## What gets replaced

| Artifact | What happens |
|---|---|
| Python app source | New image loaded from the bundle |
| `nginx/default.conf`, `nginx/portal.html` | Replaced; `kong-auth-proxy` recreated |
| `docker-compose.yml` | Replaced; `docker compose up -d` re-evaluates |

---

## Key secrets / invariants

- **`KONG_PG_PASSWORD` must match the existing Postgres volume.** Legacy installs
  use `kong_pass`; `pca-deploy.sh` preserves/creates this automatically. Only
  change it if you also destroy and recreate the volume (`docker compose down -v`),
  which **wipes all Kong route/service/plugin data**.
- Never commit `.env`, `nginx/.htpasswd`, `data/`, or `ssl/` (all gitignored).

---

## Common errors and recovery

### `KONG_PG_PASSWORD ... must be set`
`.env` is missing the line:
```bash
cd /opt/kong
grep -q '^KONG_PG_PASSWORD=' .env || echo 'KONG_PG_PASSWORD=kong_pass' | sudo tee -a .env
docker compose up -d
```

### `kong-database` unhealthy after upgrade
Password mismatch with the existing volume:
```bash
grep KONG_PG_PASSWORD /opt/kong/.env   # must be exactly: KONG_PG_PASSWORD=kong_pass
```

### Kong won't start — TLS cert path
If `KONG_SSL_CERT` points at a missing file, regenerate:
```bash
cd /opt/kong && sudo ./pca-deploy.sh --rollback   # or re-run deploy to regen ssl/
```
`pca-deploy.sh` creates `ssl/kong-proxy.{crt,key}` automatically when absent.

### A `user`-role account is locked out of Kong Manager (403)
Expected since v1.0.3 (admin-only console). Promote them:
```bash
docker exec kong-usermgmt python3 -c "import json,datetime; p='/data/users.json'; \
db=json.load(open(p)); db['users']['USERNAME']['role']='admin'; json.dump(db,open(p,'w'),indent=2)"
```

### Health check fails / can't reach `http://localhost:8002/`
```bash
docker compose logs --tail 50 kong-usermgmt
docker compose logs --tail 50 kong-auth-proxy
```
If clearly broken, roll back: `sudo ./pca-deploy.sh --rollback`.

### Port conflict (8000/8001/8002/8100/8443/8888)
```bash
ss -tlnp | grep -E '800[012]|8100|8443|8888'
```

### MFA emails not sending
Check SMTP via the admin GUI; verify the relay is reachable:
```bash
docker exec kong-usermgmt nc -zv "$SMTP_HOST" 587
```

---

## Directory reference

```
/opt/kong/                ← production install root (DEV: /DATA/kong)
├── .env                  ← secrets, auto-generated, never in git
├── pca-deploy.sh         ← PCA one-shot install/upgrade/rollback
├── deploy.sh             ← DEV/manual first-install
├── upgrade.sh            ← DEV/manual upgrade
├── docker-compose.yml
├── nginx/
│   ├── .htpasswd         ← basic-auth creds, never in git
│   ├── default.conf
│   └── portal.html
├── ssl/                  ← proxy TLS cert (per-box, never in git)
├── usermgmt/             ← Python user-management app
├── zabbix/               ← Zabbix 7.0 monitoring template + README
├── docs/                 ← DEPLOY.md, MONITORING.md
├── data/                 ← runtime state, bind-mounted, never in git
│   ├── users.json        ← accounts + roles
│   ├── audit/
│   └── smtp.json
└── backups/              ← pre-upgrade snapshots, never in git
    └── pre-upgrade-<UTC>/
        ├── config.tar.gz
        ├── dot-env.bak
        └── pg_data.sql.gz
```

> `monitoring-preview/` (DEV-only Prometheus + Loki + Grafana stack) lives in the
> repo but is **excluded** from the PCA release bundle. See [MONITORING.md](MONITORING.md).
