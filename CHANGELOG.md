# Changelog

All notable changes to the SEHC AI Gateway are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/); this project uses
semantic-ish versioning.

## [1.0.3] — 2026-06-15

Security hardening, full monitoring + alerting, and a documentation refresh.

### Highlights
- 🔒 **Admin-only console** — Kong Manager and the Admin API are now restricted to
  `admin`-role accounts.
- 🔐 **Proxy HTTPS** on `:8443` with a self-signed, per-box IP certificate.
- 📊 **Monitoring** — metrics exposed for Zabbix and Grafana, plus a self-contained
  Prometheus + Loki + Grafana preview stack with dashboards, logs, and alerts.

### Added
- **Proxy HTTPS on `:8443`** using a self-signed certificate whose SAN matches the
  box IP. `pca-deploy.sh` generates it automatically (`--cert-ip <ip>` to set the
  IP explicitly; auto-detect skips Docker bridge addresses). Port `8000` stays
  plain HTTP, so existing clients (e.g. n8n → Ollama) are unaffected.
- **Metrics via the Prometheus plugin**, exposed on a read-only **Status API
  (`:8100/metrics`)**. Enabled automatically on deploy; persists in Postgres.
  Status/latency/bandwidth/per-consumer metrics included.
- **Zabbix 7.0 template** (`zabbix/template_kong_http.xml`) — HTTP-agent scrape
  with Prometheus preprocessing, per-route LLD discovery, and triggers
  (datastore down, metrics unreachable, high 5xx). See `zabbix/README.md`.
- **DEV monitoring preview stack** (`monitoring-preview/`) — Prometheus + Loki +
  Grafana, with an 18-panel dashboard: health, request/error rates, latency
  (p95/p99), bandwidth, **consumption breakdown and ranking by route / service /
  consumer**, and **error + audit log panels** (Loki + Promtail, scoped to the
  Kong stack). Ships as its own **air-gapped bundle**
  (`scripts/build-monitoring-bundle.sh` → `kong-monitoring-bundle-v*.tar.gz`:
  config + 6 Docker images + `deploy-monitoring.sh`), separate from the lean
  gateway bundle, so it can run on PCA.
- **Alerting** — Grafana-managed alert rules (datastore down, Kong down, high 5xx)
  routed to a contact point with **email + webhook** integrations; verified
  end-to-end on DEV. Zabbix alerting (Email + Webhook media + trigger action)
  documented in `zabbix/README.md`.
- **`reset-password.sh`** — admin recovery tool. Resets a user's password and
  clears their lockout (and any IP locks) via `docker exec`, with no console
  login required — so a locked-out or forgotten-password admin can be recovered
  even though the console is admin-only. `--admin` ensures the admin role;
  `--unlock-only` just lifts the 15-minute lock.
- **Documentation** — `docs/MONITORING.md` (full monitoring deployment guide,
  Zabbix and Prometheus/Grafana paths).

### Changed
- **BREAKING (behavior):** `/`, `/users/`, `/logs/`, and `/api/` now require the
  `admin` role at the nginx layer (new `/auth/check/admin` gate). Kong Manager OSS
  has no built-in RBAC, so any logged-in user previously could read keys/secrets
  via the Admin API. A `user`-role account can still authenticate but receives a
  styled **403** on every console surface.
- `docs/DEPLOY.md` and `PCA-UPGRADE-GUIDE.md` refreshed around the unified
  `pca-deploy.sh` (fresh + upgrade auto-detect), with updated ports and v1.0.3
  surfaces.
- `pca-deploy.sh` now also generates the proxy TLS cert and enables the Prometheus
  plugin during both fresh installs and upgrades (idempotent).
- `build-release.sh` excludes `monitoring-preview/` from the PCA bundle.

### Fixed
- Stale documentation referencing the retired `pca-upgrade.sh` script (unified
  into `pca-deploy.sh`).

### Upgrade notes
- **Existing Kong config is preserved.** Services, routes, plugins, and consumers
  live in the `kong_pg_data` Postgres volume, which the upgrade does not destroy
  (it takes a `pg_dump` backup only). Users, roles, audit, SMTP, `.env`, and
  `nginx/.htpasswd` are likewise preserved.
- **Check user roles before upgrading.** Any `user`-role account will lose access
  to the console (403). Promote anyone who needs admin access first.
- **Set `--cert-ip <PCA_IP>`** when deploying so the TLS cert SAN matches how
  clients reach `:8443`.
- **Open `tcp/8100`** from the monitoring host (Zabbix / Prometheus) to the box.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.0.3.sha256.txt
tar xzf kong-pca-bundle-v1.0.3.tar.gz && cd v1.0.3
sudo ./pca-deploy.sh kong-deploy-v1.0.3.tar.gz --cert-ip <PCA_IP>
```

## [1.0.2] — earlier

- Renamed the URL path prefix `/kong` → `/aigw`.
- Self-contained release directory and single-file bundle; unified
  `pca-upgrade.sh` + `deploy.sh` into one `pca-deploy.sh` (auto-detects fresh vs
  upgrade); air-gap fixes (no `alpine:latest`, `pg_dump` for backups).

[1.0.3]: https://github.com/minh0607/kong-gateway/releases/tag/v1.0.3
