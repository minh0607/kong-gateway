# PDF reports from a Grafana dashboard

## ✅ Recommended: renderer (clean, looks exactly like the dashboard)
The renderer screenshots the WHOLE dashboard in one shot — clean layout, and it
picks up the branded logo banner (the top Text panel) automatically.

    ./generate-report.sh --grafana http://admin:<pass>@<grafana>:3000 <dashboard-uid>
    # -> kong-report.pdf  (one clean page, with logo)

Options: --from/--to, --theme light|dark, --width/--height, --out, and multiple
dashboard UIDs (one page each). Works with any datasource (incl. Zabbix).

## ❌ NOT recommended: grafana-reporter (IzakMarais)
It re-renders each panel and re-assembles them, which looks blocky/broken with
this old image (v2.3-1), and its custom-template (-templates) feature is buggy.
Prefer the renderer above. Branding is done in the dashboard (a Text panel with
the logo, kong-overview.json panel id 100), not in a LaTeX template — editable
from the Grafana UI and visible in every export.

## One clean A4 page (dedicated report dashboard)
`kong-report` ("Kong — Báo cáo (A4)") is a curated, ~59-grid-unit dashboard laid
out to fit exactly one A4 portrait page (logo banner + key panels + ranking
tables, no panel cut). Generate it with a matching render height:

    ./generate-report.sh --grafana http://admin:<pass>@<grafana>:3000 \
      --height 2000 kong-report

Edit the panels/layout in the Grafana UI or in
grafana/dashboards/kong-report.json. For a 2-page report just add more panels;
the renderer paginates to A4. Build your own A4 report for Zabbix the same way:
a curated dashboard ~59 units tall, rendered at --height 2000.
