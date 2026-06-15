#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# build-monitoring-bundle.sh — package the Prometheus + Loki + Grafana monitoring
# stack for air-gapped PCA deployment.
#
# Produces release/kong-monitoring-bundle-v<VERSION>.tar.gz containing:
#   monitoring-preview/  (git-tracked config + deploy-monitoring.sh)
#   monitoring-preview/images/*.tar  (saved Docker images, air-gap)
#
# Run on a DEV box where the monitoring images are already pulled.
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
VERSION="$(cat VERSION)"

log() { printf '\n\033[1;34m[mon-bundle]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m  ✔\033[0m  %s\n' "$*"; }
die() { printf '\033[1;31m[FATAL]\033[0m %s\n' "$*" >&2; exit 1; }

IMAGES=(
  prom/prometheus:latest
  grafana/loki:latest
  grafana/promtail:latest
  grafana/grafana:latest
  axllent/mailpit:latest
  mendhak/http-https-echo:latest
)

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
DEST="$STAGE/monitoring-preview"
mkdir -p "$DEST/images"

# ── stage git-tracked config ──────────────────────────────────────────────────
log "Staging monitoring config ..."
while IFS= read -r f; do
  rel="${f#monitoring-preview/}"
  mkdir -p "$DEST/$(dirname "$rel")"
  cp "$f" "$DEST/$rel"
done < <(git ls-files monitoring-preview/)
chmod +x "$DEST/deploy-monitoring.sh" 2>/dev/null || true
[[ -f "$DEST/docker-compose.yml" ]] || die "monitoring-preview/docker-compose.yml not staged"
ok "config staged"

# ── save images ───────────────────────────────────────────────────────────────
for img in "${IMAGES[@]}"; do
  docker image inspect "$img" >/dev/null 2>&1 || die "image not present locally: $img (docker pull it first)"
  fname="$(echo "$img" | tr '/:' '__').tar"
  log "Saving $img ..."
  docker save "$img" -o "$DEST/images/$fname"
  ok "$(du -h "$DEST/images/$fname" | cut -f1)  $fname"
done

# ── pack ──────────────────────────────────────────────────────────────────────
mkdir -p "$ROOT/release"
OUT="$ROOT/release/kong-monitoring-bundle-v${VERSION}.tar.gz"
log "Packing $OUT ..."
tar czf "$OUT" -C "$STAGE" monitoring-preview
( cd "$ROOT/release" && sha256sum "kong-monitoring-bundle-v${VERSION}.tar.gz" \
    > "kong-monitoring-bundle-v${VERSION}.sha256.txt" )

printf '\n══════════════════════════════════════════════════════════\n'
printf '  Monitoring bundle: %s\n' "$OUT"
printf '  Size:    %s\n' "$(du -sh "$OUT" | cut -f1)"
printf '  SHA256:  release/kong-monitoring-bundle-v%s.sha256.txt\n' "$VERSION"
printf '\n  On PCA (after the gateway is deployed):\n'
printf '    cd /opt/kong\n'
printf '    tar xzf kong-monitoring-bundle-v%s.tar.gz\n' "$VERSION"
printf '    sudo ./monitoring-preview/deploy-monitoring.sh\n'
printf '══════════════════════════════════════════════════════════\n'
