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
#   --width / --height  Render size px. Default: 1500 x 2600
#   --theme         light | dark. Default: light
#   --out FILE      Output PDF. Default: kong-report-<date>.pdf
#   <uid> ...       One or more dashboard UIDs (see the dashboard URL /d/<uid>/...)
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

GRAFANA="http://admin:admin@localhost:3000"
FROM="now-6h"; TO="now"; WIDTH=1500; HEIGHT=2600; THEME="light"; OUT=""
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

# combine PNG pages -> one PDF (try whatever is available)
combine() {
  if command -v img2pdf >/dev/null 2>&1; then img2pdf "$@" -o "$OUT"; return; fi
  if python3 -c 'import PIL' 2>/dev/null; then
    python3 - "$OUT" "$@" <<'PY'
import sys
from PIL import Image
out, paths = sys.argv[1], sys.argv[2:]
imgs = [Image.open(p).convert("RGB") for p in paths]
imgs[0].save(out, save_all=True, append_images=imgs[1:])
PY
    return
  fi
  if command -v convert >/dev/null 2>&1; then convert "$@" "$OUT"; return; fi
  return 1
}

if combine "${PAGES[@]}"; then
  echo ""
  echo "Report: $OUT  ($(du -h "$OUT" | cut -f1), ${#PAGES[@]} page(s))"
else
  cp "${PAGES[@]}" .
  echo ""
  echo "Rendered ${#PAGES[@]} PNG page(s) to the current dir, but no PNG->PDF tool found."
  echo "Install one of: img2pdf | python3-Pillow | imagemagick, then combine:"
  echo "   img2pdf page-*.png -o $OUT"
fi
