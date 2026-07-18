# Deployment (Air-Gapped)

> How the gateway is packaged and installed on the PCA, which has **no internet**.
> Everything the deploy needs must be inside the bundle or an already-loaded image.

---

## 1. Environments

| Environment | Path | Notes |
|---|---|---|
| DEV | `/DATA/kong/` (e.g. `192.168.1.121`) | Build + test box |
| PCA (production) | `/opt/kong/` | Air-gapped; installed from a USB bundle |

## 2. Build a release (on DEV)

```bash
cd /DATA/kong
scripts/build-release.sh
```

This produces `release/v<X.Y.Z>/` containing:

- `kong-deploy-v<X.Y.Z>.tar.gz` — code + bundled `images/kong-usermgmt.tar`
- `pca-deploy.sh` — one-shot install / upgrade / rollback wrapper (auto-detects mode)
- `images/{kong-oss-3.9, postgres-15-alpine, nginx-alpine}.tar` — base images
- `PCA-UPGRADE-GUIDE.md`, `README.txt`

It also builds a single USB file: `release/kong-pca-bundle-v<X.Y.Z>.tar.gz`
(~266 MB) plus a `*.sha256.txt` checksum.

Only **git-tracked** files are packaged, so per-box secrets (the `ssl/` cert/key,
`nginx/.htpasswd`) never leave DEV.

## 3. Install / upgrade on the PCA

```bash
# verify + unpack the USB bundle
sha256sum -c kong-pca-bundle-v<X.Y.Z>.tar.gz.sha256.txt
tar xzf kong-pca-bundle-v<X.Y.Z>.tar.gz
cd v<X.Y.Z>

# one-shot deploy (auto-detects fresh vs upgrade)
sudo ./pca-deploy.sh kong-deploy-v<X.Y.Z>.tar.gz --cert-ip <PCA_IP>
```

`pca-deploy.sh` handles, idempotently and air-gap-safe:

- Loads the bundled Docker images (no `docker compose build`, no registry pull).
- Ensures `.env` has `SESSION_SECRET`, `KONG_PG_PASSWORD`, `SMTP_HOST`.
- **`ensure_proxy_cert()`** — generates the proxy TLS cert via `openssl` with the
  correct SAN (`--cert-ip`), owner `root:1001`, mode `640` (Kong runs as uid 1001).
- Bootstraps the Kong DB (migrations), brings the stack up.
- **`enable_prometheus_plugin()`** — enables the Prometheus plugin globally.
- Backs up existing data via `pg_dump` (from the running container) before an upgrade.

Modes: **fresh install**, **upgrade** (preserves Postgres volume + `data/`), and
**rollback** — all detected automatically.

## 4. Air-gap rules (why deploys used to break)

Every image/tool a script uses **must** be in the bundle or already loaded. Past
production failures and their fixes:

| Failure | Cause | Fix |
|---|---|---|
| htpasswd fallback | pulled `httpd:2.4-alpine` | use already-loaded `kong-usermgmt` |
| tar backup | pulled `alpine:latest` | use `pg_dump` from the running container |
| build step | `docker compose build` needs `apk add` | pre-build `kong-usermgmt` image at release time |

## 5. Environment variables (`.env`)

| Var | Purpose |
|---|---|
| `SESSION_SECRET` | HMAC key for session cookies (32-byte hex, auto-generated; refuse-to-boot if default). |
| `KONG_PG_PASSWORD` | Postgres password. Changing it on an existing install requires `down -v` (destroys data). |
| `SMTP_HOST` | Internal SMTP relay for MFA / notifications. Override per-env via `data/smtp.json`. |
| `SMTP_USER` / `SMTP_PASS` | Optional SMTP credentials. |
| `MFA_ENFORCED` | `true` forces MFA for all users (kill-switch). Default `false`. |

## 6. Post-deploy verification

```bash
# proxy up
curl -s http://<PCA_IP>:8000/  # Kong "no Route matched" is expected with no path
# admin API reachable (internal)
curl -s http://localhost:8001/services | head
# status/metrics for monitoring
curl -s http://<PCA_IP>:8100/metrics | head
# console
#   http://<PCA_IP>:8002/aigw/   or   http://<PCA_IP>/aigw/ via IT Portal
```
