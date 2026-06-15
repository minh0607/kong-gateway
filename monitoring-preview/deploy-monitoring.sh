#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# deploy-monitoring.sh — bring up the Prometheus + Loki + Grafana monitoring
# stack for Kong, air-gapped. Loads bundled images, then starts the stack.
#
# Extract the monitoring bundle INTO the Kong install dir so the relative paths
# resolve, e.g. on PCA:
#     cd /opt/kong
#     tar xzf kong-monitoring-bundle-vX.Y.Z.tar.gz      # -> /opt/kong/monitoring-preview/
#     sudo ./monitoring-preview/deploy-monitoring.sh
#
# Requires the Kong stack to be running already (shares its `kong_kong-net`
# network and reads ../data/audit for the audit log panel).
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ -t 1 ]]; then
  C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_RST=$'\033[0m'
else
  C_GRN= C_YEL= C_RED= C_RST=
fi
log()  { printf '%s[monitoring]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s  ⚠%s  %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '%s  ✘%s  %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

# ── pre-flight ────────────────────────────────────────────────────────────────
command -v docker >/dev/null || die "docker not installed / not in PATH"
docker compose version >/dev/null 2>&1 || die "docker compose v2 not available"
docker network inspect kong_kong-net >/dev/null 2>&1 \
  || die "network 'kong_kong-net' not found — deploy the Kong stack first (pca-deploy.sh)"

# ── load bundled images (air-gap; no pull) ────────────────────────────────────
if [[ -d images ]]; then
  shopt -s nullglob
  for tar in images/*.tar; do
    log "Loading image $(basename "$tar") ..."
    docker load -i "$tar" >/dev/null
  done
  shopt -u nullglob
else
  warn "no images/ dir — assuming Prometheus/Grafana/Loki images are already loaded"
fi

# ── bring up the stack ────────────────────────────────────────────────────────
log "Starting Prometheus + Loki + Promtail + Grafana ..."
docker compose up -d

# ── wait + report ─────────────────────────────────────────────────────────────
for i in $(seq 1 30); do
  curl -sf http://localhost:3000/api/health >/dev/null 2>&1 && break
  sleep 1
done
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
IP="${IP:-<host-ip>}"

cat <<EOF

${C_GRN}══════════════════════════════════════════════════════════${C_RST}
  ${C_GRN}Monitoring stack up${C_RST}

  Grafana:     http://${IP}:3000      (admin / admin)
               dashboard "Kong Gateway — Overview"
  Prometheus:  http://${IP}:9090
  Mailpit:     http://${IP}:8026      (captured alert emails)

  Scrapes kong:8100 over the kong_kong-net network. Alert email/webhook use the
  bundled mailpit + echo sink (same as DEV) — repoint them at your real SMTP relay
  / internal endpoint in grafana/provisioning/alerting/ when ready.
${C_GRN}══════════════════════════════════════════════════════════${C_RST}
EOF
