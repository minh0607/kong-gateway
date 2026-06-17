# PDF reports from a Grafana dashboard

Two ways, both use the bundled `grafana-image-renderer` (already in the stack):

## A. Single dashboard -> PDF/PNG (simple)
Use the renderer directly:
    ./generate-report.sh --grafana http://admin:<pass>@<grafana>:3000 <dashboard-uid>

## B. Multi-page report with title + time range + page numbers (grafana-reporter)
`grafana-reporter` (IzakMarais) renders each panel and assembles a paginated PDF.
Run it pointed at your Grafana (works with the Zabbix datasource too):

    # one-time: create a Grafana service-account token (Admin) and note it
    docker run -d --name grafana-reporter --network <grafana-net> -p 8686:8686 \
      izakmarais/grafana-reporter -ip <grafana-host>:3000 -grid-layout 1

    # generate (apitoken = the service-account token)
    curl "http://localhost:8686/api/v5/report/<uid>?apitoken=<TOKEN>&from=now-1h&to=now" -o report.pdf

Notes:
- `-ip` is host:port WITHOUT http:// (the tool prepends it).
- The reporter's `-templates` (custom LaTeX) is BROKEN in the current image
  (v2.3-1) — do NOT use it. For branding, add a logo via a Grafana **Text panel**
  at the top of the dashboard instead (see kong-overview.json, panel id 100):
  it shows up in every export and is editable from the Grafana UI.
- For HTTPS Grafana with a self-signed cert add `-ssl-check=false`.
