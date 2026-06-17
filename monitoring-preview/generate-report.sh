#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# generate-report.sh — export one or more Grafana dashboards to a single PDF
# report, using the grafana-image-renderer service (OSS-friendly, no Enterprise).
#
# Renders each dashboard to a full-page PNG via Grafana's /render API, then
# combines the pages into one PDF.
#
#   ./generate-report.sh kong-overview
#   ./generate-report.sh --from now-24h --to now --out kong-daily.pdf kong-overview other-uid
#
# Options:
#   --grafana URL   Grafana base URL. Default: http://admin:admin@localhost:3000
#   --from / --to   Time range. Default: now-6h .. now
#   --width / --height  Render size px. Default: 1500 x 2900
#   --theme         light | dark. Default: light
#   --out FILE      Output PDF. Default: kong-report-<date>.pdf
#   <uid> ...       One or more dashboard UIDs (see the dashboard URL /d/<uid>/...)
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

GRAFANA="http://admin:admin@localhost:3000"
FROM="now-6h"; TO="now"; WIDTH=1500; HEIGHT=2900; THEME="light"; OUT=""
UIDS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --grafana) shift; GRAFANA="${1:?}" ;;
    --from)    shift; FROM="${1:?}" ;;
    --to)      shift; TO="${1:?}" ;;
    --width)   shift; WIDTH="${1:?}" ;;
    --height)  shift; HEIGHT="${1:?}" ;;
    --theme)   shift; THEME="${1:?}" ;;
    --out)     shift; OUT="${1:?}" ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        echo "unknown flag: $1" >&2; exit 1 ;;
    *)         UIDS+=("$1") ;;
  esac; shift
done
[[ ${#UIDS[@]} -gt 0 ]] || { echo "give at least one dashboard UID (see --help)"; exit 1; }
[[ -n "$OUT" ]] || OUT="kong-report.pdf"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PAGES=()
i=0
for uid in "${UIDS[@]}"; do
  i=$((i+1)); png="$TMP/page-$(printf '%02d' "$i").png"
  url="$GRAFANA/render/d/$uid/r?orgId=1&from=$FROM&to=$TO&width=$WIDTH&height=$HEIGHT&theme=$THEME&kiosk=true"
  echo "Rendering dashboard '$uid' ..."
  code="$(curl -s -o "$png" -w '%{http_code}' "$url")"
  [[ "$code" == "200" ]] || { echo "  render failed (HTTP $code) for '$uid'"; continue; }
  [[ "$(head -c8 "$png" | xxd -p)" == "89504e470d0a1a0a" ]] || { echo "  not a PNG for '$uid'"; continue; }
  echo "  ok ($(du -h "$png" | cut -f1))"
  PAGES+=("$png")
done
[[ ${#PAGES[@]} -gt 0 ]] || { echo "no pages rendered — check Grafana/renderer"; exit 1; }

# combine rendered dashboard PNGs -> one A4-PORTRAIT PDF (scaled to width, paginated)
python3 -c 'import PIL' 2>/dev/null || {
  echo "Need python3 Pillow to build the A4 PDF:  pip install Pillow" >&2
  cp "${PAGES[@]}" . ; echo "Left the rendered PNGs in the current dir." >&2; exit 1; }

python3 - "$OUT" "${PAGES[@]}" <<'PY'
import sys
from PIL import Image
out, paths = sys.argv[1], sys.argv[2:]
A4W, A4H, M = 1240, 1754, 48          # A4 portrait @150dpi, 48px (~8mm) margin
cw, ch = A4W - 2*M, A4H - 2*M
pages = []
for p in paths:
    im = Image.open(p).convert("RGB")
    im = im.resize((cw, max(1, round(im.height * cw / im.width))), Image.LANCZOS)
    y = 0
    while y < im.height:
        pg = Image.new("RGB", (A4W, A4H), "white")
        pg.paste(im.crop((0, y, cw, min(y + ch, im.height))), (M, M))
        pages.append(pg); y += ch
pages[0].save(out, "PDF", resolution=150.0, save_all=True, append_images=pages[1:])
print(f"PAGES={len(pages)}")
PY

echo ""
echo "Report: $OUT  ($(du -h "$OUT" | cut -f1), A4 portrait, ${#PAGES[@]} dashboard(s))"
