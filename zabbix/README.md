# Kong Gateway — Zabbix 7.0 template

Monitors Kong OSS through its Prometheus plugin, scraped over HTTP. No agent on the
Kong box is required — Zabbix pulls `/metrics` from the Kong Status API.

```
Kong  ──/metrics (port 8100)──▶  Zabbix (HTTP agent + Prometheus preprocessing)  ──▶  Grafana (Zabbix datasource)
```

## Prerequisites (on the Kong side)

Already wired into this repo (`docker-compose.yml` + `pca-deploy.sh`):

- `KONG_STATUS_LISTEN=0.0.0.0:8100` → Status API serves `/metrics`.
- Prometheus plugin enabled globally with status_code / latency / bandwidth /
  per_consumer metrics.

Verify from the Kong box:

```bash
curl -s http://localhost:8100/metrics | grep -c '^kong_'   # > 0
```

Make sure the **Zabbix server can reach `tcp/8100`** on the Kong host (firewall).

## Import the template

1. Zabbix UI → **Data collection → Templates → Import**.
2. Choose `template_kong_http.xml`. Zabbix detects format **7.0**.
3. Confirm. It creates template **"Kong Gateway by HTTP"** under
   *Templates/Applications*.

## Create the Kong host

1. **Data collection → Hosts → Create host**.
2. **Host name**: e.g. `kong-prod`.
3. **Interfaces** → add an interface (Agent type is fine) with the **IP/DNS of the
   Kong box**. The template's HTTP item uses `{HOST.CONN}`, so this interface IP is
   where Zabbix scrapes `:8100/metrics`.
4. **Templates** → link **Kong Gateway by HTTP**.
5. (Optional) **Macros** — override defaults if needed:

   | Macro | Default | Meaning |
   |---|---|---|
   | `{$KONG.STATUS.PORT}` | `8100` | Status API port |
   | `{$KONG.SCRAPE.INTERVAL}` | `60s` | Scrape frequency |
   | `{$KONG.NODATA}` | `5m` | No-data window before "unreachable" alert |
   | `{$KONG.5XX.RATE.WARN}` | `1` | 5xx rps threshold for warnings |

Within ~1–2 intervals you should see data under **Monitoring → Latest data**, and
routes auto-discovered (the `n8n` / `ollaman8n` route appears as `{#ROUTE}`).

## What you get

**Node-level items**
- `kong.datastore_reachable` — Postgres reachability (1/0) + HIGH trigger
- `kong.connections.active` — active nginx connections
- `kong.requests.rate` — total requests/sec
- `kong.requests.5xx.rate` — 5xx/sec + WARNING trigger
- Metrics-unreachable trigger (`nodata` on the raw scrape)

**Per-route items (auto-discovered via LLD)**
- request rate, 4xx rate, 5xx rate (+ per-route 5xx trigger)
- egress / ingress bandwidth (bytes/sec)
- average Kong latency (ms) — derived from delta(sum)/delta(count)

## Grafana

Grafana is wired to the **Zabbix datasource**, so build panels by selecting the
Kong host and the items above (e.g. `Route [n8n]: request rate`). The community
Prometheus dashboard (Grafana ID 7424) is **not** used — it needs a Prometheus
datasource, not Zabbix.

## Notes

- Request/bandwidth/latency counters are converted to per-second rates inside
  Zabbix (Change per second), so graphs show current load, not lifetime totals.
- 4xx/5xx items default to `0` (not "unsupported") when a route has had no such
  responses yet.
- The two `*latency.*.rate (internal)` items exist only to compute average
  latency; you normally graph `kong.route.latency.avg` instead.
