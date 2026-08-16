# Changelog

All notable changes to the SEHC AI Gateway are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/); this project uses
semantic-ish versioning.

## [1.0.9] — 2026-08-10

Tell plugins apart and see the whole gateway at a glance.

### Added
- **Topology tab** — one holistic map of the gateway: each service shown with its
  routes, its plugins (by name **and instance name**, with a config summary), its
  ACL groups, and the consumers that can call it (via which group, key count,
  allowed IPs). Answers "which service uses which route / plugin / ACL / consumer"
  in a single screen, with a live filter across service / plugin / consumer.
- **Plugin instance names.** Plugins can now be given an `instance_name` when
  added or edited, and the Plugins tab shows it as the primary label (with the
  plugin type as a sub-tag) — so multiple plugins are easy to tell apart instead
  of a wall of same-typed rows.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.0.9.sha256.txt
tar xzf kong-pca-bundle-v1.0.9.tar.gz && cd v1.0.9
sudo ./pca-deploy.sh kong-deploy-v1.0.9.tar.gz --cert-ip <PCA_IP>
```

## [1.0.8] — 2026-08-07

UX polish + a portal-serving reliability fix, from a parallel UX-review + QA-agent
cross-check of all 13 tabs (all functions verified PASS, 0 JS errors).

### Fixed
- **Portal survives a file swap.** The auth-proxy bind-mounted the *single file*
  `portal/portal.html`; replacing it on the host (new inode) made nginx **404
  `/kongportal`** until a container restart. Now the **directory** is mounted
  (`./portal → /etc/nginx/model-portal`, `alias …/portal.html`), so updating the
  file is served immediately — verified by rewriting the file live (stays 200).
- **Plugins tab used emoji** for the built-in protections (🔑 key-auth, 👥 acl,
  ⏱ rate-limiting, 📦 request-size-limiting, 🤖 bot-detection, 🌐 cors, 🔌) — now
  inline **SVG (Heroicons-style)**, so they're consistent and render correctly in
  dark mode.
- **No horizontal overflow on mobile (≤640px).** Grid `.split` children now carry
  `min-width:0` so wide tables scroll inside their own container instead of
  pushing the page; card-header toolbars wrap; schema-form (`.pfrow`) inputs go
  full-width. Verified 0 overflow across all 13 tabs at 375px.
- **Requests** status codes render as **semantic badges** (not bare colored text).
- **Test** body textarea is monospace and taller; **Backup** file input + all
  textareas are styled for dark mode (no white flash) and the export counts sit in
  a 2-column grid.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.0.8.sha256.txt
tar xzf kong-pca-bundle-v1.0.8.tar.gz && cd v1.0.8
sudo ./pca-deploy.sh kong-deploy-v1.0.8.tar.gz --cert-ip <PCA_IP>
```

## [1.0.7] — 2026-08-07

Portal layout fix — fill wide screens.

### Fixed
- **The portal now fills wide monitors.** The content container was hard-capped
  at `max-width:1180px`, leaving a ~500px empty band on the right of a 1920px
  screen (the topbar filled, the body did not — looking "squished"). Raised the
  cap to a full-width workbench (`max-width:2100px`, centered) so it fills up to
  ~2340px windows and only centers on ultra-wide (2560/3440) for readable line
  lengths. Verified from 320→2560px with no horizontal overflow.
- **Wizard and Plugins tabs** (each a single fixed-width card) are now centered
  instead of left-dumped, so their whitespace is balanced.
- **Collapsed sidebar (<900px)** hardened: the wide logo no longer overflows the
  64px rail (it was overlapping the page title), the connection-status text is
  hidden, and the footer toggle is centered.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.0.7.sha256.txt
tar xzf kong-pca-bundle-v1.0.7.tar.gz && cd v1.0.7
sudo ./pca-deploy.sh kong-deploy-v1.0.7.tar.gz --cert-ip <PCA_IP>
```

## [1.0.6] — 2026-08-07

Portal management upgrades — cover the full Kong object model, make plugin config
foolproof, add a Setup Wizard, and align the UI to the IT Portal design system.
The portal is now a full web console (13 tabs) beside `kong-manage.sh`; see
`docs/confluence/09-model-portal.md`.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.0.6.sha256.txt
tar xzf kong-pca-bundle-v1.0.6.tar.gz && cd v1.0.6
sudo ./pca-deploy.sh kong-deploy-v1.0.6.tar.gz --cert-ip <PCA_IP>
```
Upgrade-safe: no `down -v`, a `pg_dump` backup is taken first, and only changed
containers restart. After deploy, open `https://<PCA_IP>:8452/kongportal` and
check the Overview health strip has **no** stray global-auth warning.

### Added
- **Consumers tab** — add any consumer (incl. non-convention / legacy names),
  manage ACL group membership (add/remove groups), and **issue / view / delete
  API keys** (`key-auth` credentials — blank = auto-generate a 36-char secure
  key). Lists **every** consumer with its groups, keys and tags, so pre-existing
  config (e.g. `n8n`) is visible, not hidden by the `prj-` convention.
- **Upstreams tab** — create load-balancing pools (round-robin / least-connections
  / consistent-hashing), add backend targets (`host:port` + weight) with health
  badges, remove targets or delete upstreams. Point a model's backend host at an
  upstream name to spread traffic across targets.
- **Usage tab** — per-consumer traffic **broken down by model**: requests, 5xx
  errors and in/out bandwidth for each `consumer × service`, parsed live from
  Kong's Prometheus metrics. A new admin-gated `/metrics` nginx location proxies
  the read-only Status API (`:8100/metrics`) so the SPA can read it same-origin;
  only key-auth-authenticated traffic is attributed to a consumer.
- **Requests tab** — recent requests with **source IP**: time, client IP,
  consumer, model, status and latency (who called which model from where).
  Backed by a global **`file-log`** plugin writing one JSON line per request to
  a shared `data/reqlog/requests.log`; nginx serves it read-only at `/requests`
  (admin-gated) and the SPA Range-fetches only the tail. `pca-deploy.sh` enables
  the plugin, creates the dir, and installs a **logrotate** rule (10M ×3) so the
  log cannot fill the disk. Note: behind an L4 proxy, set Kong `trusted_ips` +
  `real_ip_header` to log the true client IP instead of the proxy's.
- **"Show all (incl. legacy)"** toggle on the Models tab — lists every Kong
  service, tagging non-`svc-` ones as `legacy`, so pre-existing services appear.
- **Inline edit** on Models rows — change a service's backend URL and route path
  (works for `svc-*` and legacy services).

### Changed (Design — align to IT Portal)
- Re-aligned the portal to the **IT Portal design system** (`/DATA/itportal`
  DESIGN.md): default primary shifted to Action Blue **#3b82f6** (hover #2563eb),
  gradient primary/danger buttons with a colored shadow and focus ring, ink text
  **#0f172a**. Sidebar emoji icons replaced with **inline SVG (Heroicons-style)
  outline icons** — self-hosted, air-gap safe. Stat cards gained a colored top
  accent and a lift-on-hover, matching the IT Portal dashboard. Both light and
  dark themes verified.
- Card headers now use **colored gradient icon tiles** (blue/violet/green/amber/
  sky) with white Heroicons-style SVGs — matching the IT Portal Quick-Actions
  style — replacing the remaining emoji in section titles.

### Added (Setup Wizard)
- **Wizard tab** — a 4-step guided flow (Model → Route → Project → Review) that
  provisions a full working path in one shot: a service (`svc-<slug>` + key-auth
  + `acl-<slug>`), its route, and a project (`prj-<name>` with token, ACL
  membership and optional IP restriction), ending in a review summary. The last
  emoji (Generate, reveal) are now inline SVG too.
  - **Two modes:** *Create a new model* (greenfield) or *Use an existing model*
    — the latter skips service/route creation, auto-detects the model's ACL
    group / key-header / route, and just adds a new project to it. New mode
    **guards against an existing slug** (won't overwrite a model) — telling you
    to switch to existing mode instead.

### Added (Governance & convenience — P2)
- **Audit tab** — admin change log: who did what (actor, source IP, method →
  Create/Update/Delete, object, result), newest first, defaulting to changes
  only (hides reads) with a text filter. Surfaces the existing nginx audit log
  via a new admin-gated `/auditlog` location (Range-tailed like Requests).
- **CSV export** on the Usage and Requests tabs — one-click download for
  reporting/spreadsheets.
- **Quick filters** on the Models, Routes, Consumers and Projects tables —
  instant client-side row filtering.

### Added (Operations — P1)
- **Test tab** — send a real request through Kong with a chosen project's key and
  see the status, latency and response body. Goes through the actual key-auth /
  ACL / routing pipeline via a new admin-gated `/modeltest/` nginx location that
  proxies the Kong proxy port (`:8000`), so 401 (bad key), 403 (ACL) and 5xx
  (upstream) are all reproduced exactly like a client would see them.
- **Health strip on Overview** — Kong version, database reachability, active
  connections and upstream target health, with a re-check link. Also **flags a
  stray GLOBAL auth plugin** (basic-auth / key-auth / jwt / oauth2 / hmac-auth /
  ldap-auth / mtls-auth): such a plugin applies to every route and 401s all
  API-key traffic — a red banner warns to remove it unless intentional.
- **Backup tab** — **Export** the whole gateway config (services, routes,
  plugins, consumers, ACLs, API keys, upstreams, targets) to a JSON file, and
  **Restore** it from a file. Restore upserts every entity by id (idempotent —
  updates existing, recreates missing) and never deletes. Verified via a headless
  round-trip (export → delete a service → restore → service recreated with its
  route). The export contains API keys in clear text — store it securely.

### Added (CRUD completeness — P0)
- **Routes tab** — routes are first-class now: list every route (path, service,
  methods, strip_path), add many routes per service (paths / methods / hosts /
  strip_path), edit and delete them. Fills the "one service = many routes" gap.
- **Delete a model** — Models rows get a Delete that removes the service, all its
  routes and plugins (consumers/keys untouched).
- **Edit a project** — change a project's allowed models (ACL groups), IPs and
  tags without delete-and-recreate; the token is preserved. ACL membership is
  diffed (adds selected, removes deselected); clearing IPs removes the
  ip-restriction.
- **Edit any plugin** — every attached plugin (not just the curated toggles) gets
  an Edit that opens the schema-driven form prefilled with its current config;
  enable/disable and delete were already there.
- **Edit a consumer** — rename (PATCH by id, so keys/ACL survive) and change tags
  from the Consumers tab.

### Changed
- **Legacy config is no longer hidden.** The Models list defaults to **showing
  all** services with a `managed` / `legacy` badge (was: convention-only with an
  opt-in "Show all"). Nothing is hidden by default.
- **Plugin config is now a schema-driven form, not raw JSON.** The "Add any
  plugin" picker renders typed inputs generated from the plugin's Kong schema
  (`GET /schemas/plugins/<name>`) — number / text / checkbox / select (one_of) /
  comma-list (arrays), prefilled with defaults. Filling the fields builds and
  POSTs the config automatically; the error-prone JSON textarea is gone.

### Notes
- Portal changes are UI-only over the existing authenticated `/api` Admin proxy —
  no schema, port, or auth changes. Rebuild the PCA bundle to ship these.

## [1.0.5] — 2026-07-28

Model & Project self-service portal, integrated into the console over HTTPS.

### Added
- **Model & Project Portal** at `/kongportal` (also `/aigw/kongportal` via the IT
  Portal forward). A single-page admin UI over the Kong Admin API implementing the
  3-axis convention: register models (`svc-<slug>` + route + tags), assign projects
  (`prj-<slug>` consumers with their own token + IP), an **Overview** with a
  model↔project access matrix, and a **Plugins** tab (per-model protection toggles
  for key-auth/acl/rate-limiting/request-size-limiting/bot-detection/cors, plus a
  full picker for any Kong plugin with JSON config). ITPortal styling — SEHC INFRA
  logo, blue/slate palette, Inter, dark mode.
- Served **behind the same admin login as the console** (`_auth_check_admin`):
  anonymous users are redirected to `/auth/login`, non-admins get 403. Its API
  calls reuse the authenticated `/api` Admin proxy — no new auth surface. Switch
  links added between the console and the portal.
- **HTTPS on the auth-proxy** (`listen 443 ssl`, published on `:8452`) using the
  box's self-signed cert (`ssl/kong-proxy.*`, generated by `ensure_proxy_cert`).
  HTTP `:8002` is kept for the IT Portal forward.

### Notes
- `portal/serve-portal.py` is a DEV-only helper (no auth); production access is
  `/kongportal` behind the login.

## [1.0.4] — 2026-07-26

Monitoring release: turn on vLLM token monitoring end-to-end and ship it to PCA.

### Added
- **vLLM scrape job** in `monitoring-preview/prometheus.yml` (`job_name: vllm` via
  `file_sd_configs`), plus `vllm-targets.yml` pre-populated with the 7 production
  vLLM hosts (`107.118.109.31–36`, `.46`). Prometheus hot-reloads the target file
  (~30s) — add/remove machines without a restart.
- Grafana **"vLLM Token Usage"** panels (token rate by model/machine) are wired to
  the same Prometheus datasource that scrapes Kong — one stack monitors both.

### Notes
- Each vLLM host must run **without** `--disable-log-stats`, listen on
  `0.0.0.0:<port>`, and allow the Prometheus host through the firewall.
- A separate share-externally dashboard variant (datasource prompt on import +
  Grafana-12-compatible ranked tables) is available for importing into other
  Grafana instances; the provisioned copies keep concrete datasource UIDs.

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
- **Client cert-trust scripts** (`client/`) — `trust-kong-cert.sh` (Linux:
  Debian/Ubuntu + RHEL/Fedora) and `trust-kong-cert.ps1` (Windows) so client
  machines trust the self-signed proxy cert and call `:8443` over HTTPS without
  `-k` / "allow self-signed".
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
- Proxy TLS cert unreadable by Kong on a normal filesystem: the cert key was
  created `600` and root-owned, but Kong runs as a non-root user (uid/gid 1001),
  so it could not load TLS and the container never became healthy ("dependency
  failed to start: container kong is unhealthy"). `pca-deploy.sh` now sets
  group/world-readable perms and re-asserts them on re-run.
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
