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
