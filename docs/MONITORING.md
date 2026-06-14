# SEHC AI Gateway — Monitoring Deployment Guide

How to monitor the gateway in production: traffic, consumption (per route /
service / consumer), error logs, and alerting.

There are two supported paths — you can run **either or both**:

| Path | Use when | Where it lives |
|---|---|---|
| **A. Zabbix + Grafana** | You already run Zabbix + Grafana (Grafana on the Zabbix datasource) | `zabbix/template_kong_http.xml` |
| **B. Prometheus + Loki + Grafana** | You want a self-contained stack with metrics **and** log viewing | `monitoring-preview/` |

Both consume the **same** data the gateway already exposes — you don't choose at
the Kong layer, only at the consumer layer.

---

## 1. What the gateway exposes (already enabled on deploy)

`pca-deploy.sh` configures this automatically — nothing to turn on manually:

- **Status API** on `:8100` — read-only, serves `/status` + `/metrics`
  (Prometheus exposition format). Safer to expose than the Admin API (`:8001`).
- **Prometheus plugin** enabled globally (status code + latency + bandwidth +
  per-consumer metrics). Stored in Postgres, so it persists across upgrades.

### Verify on PCA after deploy

```bash
curl -s http://localhost:8100/metrics | grep -c '^kong_'      # > 0
curl -s http://localhost:8100/status                          # JSON, database.reachable=true
```

Key metrics: `kong_http_requests_total{route,code,consumer,service}`,
`kong_bandwidth_bytes{direction}`, `kong_kong_latency_ms_{sum,count}`,
`kong_request_latency_ms_bucket`, `kong_datastore_reachable`.

> **Firewall:** the monitoring host (Zabbix server / Prometheus) must reach
> `tcp/8100` on the PCA box.

---

## Path A — Zabbix + Grafana (existing house system)

Flow: **Kong `/metrics` → Zabbix (HTTP agent + Prometheus preprocessing) → Grafana (Zabbix datasource)**.

### A1. Import the template
Zabbix UI → **Data collection → Templates → Import** → `zabbix/template_kong_http.xml`
(Zabbix detects format **7.0**). Creates **"Kong Gateway by HTTP"**.

### A2. Create the Kong host
**Data collection → Hosts → Create host** → add an interface with the **PCA box
IP** → link the template. Optional macros:

| Macro | Default | Meaning |
|---|---|---|
| `{$KONG.STATUS.PORT}` | `8100` | Status API port |
| `{$KONG.SCRAPE.INTERVAL}` | `60s` | Scrape frequency |
| `{$KONG.5XX.RATE.WARN}` | `1` | 5xx rps warning threshold |

The template auto-discovers routes (LLD) and provides per-route request / 4xx /
5xx rates, bandwidth, and average latency, plus node-level health.

### A3. Grafana panels
Grafana is on the **Zabbix datasource** → build panels by selecting the Kong host
and its items (e.g. `Route [n8n]: request rate`). For consumption ranking
(who consumes most/least) use the Zabbix items per route/service and sort.

### A4. Alerting
The template ships triggers (datastore down, metrics unreachable, high 5xx). To
notify, configure **Media types (Email + Webhook) + a Trigger action** on the
Zabbix server. Air-gap: Email via the internal SMTP relay; Webhook to a LAN
endpoint.

→ **Full detail, macro reference, LLD, and the alerting setup:**
[`zabbix/README.md`](../zabbix/README.md).

---

## Path B — Prometheus + Loki + Grafana (self-contained)

A complete observability stack (metrics + logs + alerting) in one Grafana. Lives
under [`monitoring-preview/`](../monitoring-preview/). It is **not** part of the
PCA release bundle (DEV-only by default) — to use it in production, copy the
directory across and bundle the images for the air-gapped host.

### B1. Run it
```bash
docker compose -f monitoring-preview/docker-compose.yml up -d
# Grafana    http://<host>:3000   (admin / admin)  — dashboard "Kong Gateway — Overview"
# Prometheus http://<host>:9090
```
It joins the Kong network and scrapes `kong:8100` directly.

### B2. What you get (18-panel dashboard)
- Health: datastore reachable, active connections, total req/s, 5xx/s
- **Consumption breakdown + ranking** by route / service / consumer (most vs least)
- Latency p95/p99, bandwidth in/out
- **Logs** (via Loki + Promtail): Kong stack error logs + auth/admin audit log
  — covers Kong proxy (5xx/upstream/plugin), container/system, audit, Postgres

### B3. Alerting
Provisioned alert rules (datastore down, Kong down, high 5xx) → contact point
`kong-notify` with **Email + Webhook** integrations. Configured under
`monitoring-preview/grafana/provisioning/alerting/`.

- **Email**: set `GF_SMTP_HOST` to the internal SMTP relay (DEV demo uses mailpit).
- **Webhook**: point the contact point URL at your internal endpoint (DEV demo
  uses an echo sink). On PCA, both targets must be on the LAN.

### Air-gap notes (if promoting Path B to production)
- Bundle the images offline: `prom/prometheus`, `grafana/grafana`, `grafana/loki`,
  `grafana/promtail` (+ `axllent/mailpit`, `mendhak/http-https-echo` only if you
  keep the DEV demo receivers).
- Promtail is scoped to the Kong stack containers only (`kong`, `kong-database`,
  `kong-usermgmt`, `kong-auth-proxy`).

---

## What to watch (both paths)

| Question | Metric / query |
|---|---|
| Is the gateway up? | `kong_datastore_reachable`, scrape `up` |
| Who consumes most/least? | `kong_http_requests_total` summed by `consumer` / `service` / `route` |
| Error rate? | `kong_http_requests_total{code=~"5.."}` rate |
| Latency? | `kong_request_latency_ms_bucket` (p95/p99) or `_sum`/`_count` avg |
| Bandwidth? | `kong_bandwidth_bytes{direction}` |
| System errors / failures? | container + audit logs (Path B / Loki) |

---

## Quick reference — ports

| Port | Service | Exposed to |
|---|---|---|
| `8000` | Kong proxy (HTTP) | API clients |
| `8443` | Kong proxy (HTTPS, self-signed IP cert) | API clients needing TLS |
| `8100` | Status API `/metrics` | Zabbix / Prometheus (monitoring host) |
| `8002` | Kong Manager UI (admin-only since v1.0.3) | admins |
