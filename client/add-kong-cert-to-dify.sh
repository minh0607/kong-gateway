#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# add-kong-cert-to-dify.sh — let a Dockerized Dify TRUST the gateway's self-signed
# proxy cert (so it can call the gateway over HTTPS :8443) WITHOUT losing trust in
# any other CA. It builds a combined CA bundle = Dify's real CA set (from certifi
# inside the container) + the Kong cert, and wires it in via a docker-compose
# OVERRIDE file — the original compose is never touched.
#
# Run from the Dify directory (where docker-compose.yaml lives), or pass --dify-dir.
#
#   ./add-kong-cert-to-dify.sh --cert kong-proxy.crt --gateway 107.118.99.200:8443
#
# Options:
#   --cert <file>       Kong proxy cert (PEM). Default: ./kong-proxy.crt
#   --gateway H:PORT    Gateway host:port to TLS-test after applying (optional)
#   --dify-dir <dir>    Dify compose dir. Default: current dir
#   --api-service <s>   Default: api
#   --worker-service <s> Default: worker
#   --revert            Remove the override + bundle and recreate (undo)
#
# Undo any time:  ./add-kong-cert-to-dify.sh --revert
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CERT="kong-proxy.crt"; GATEWAY=""; DIFY_DIR="."; API="api"; WORKER="worker"; REVERT=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cert)            shift; CERT="${1:?}" ;;
    --gateway)         shift; GATEWAY="${1:?}" ;;
    --dify-dir)        shift; DIFY_DIR="${1:?}" ;;
    --api-service)     shift; API="${1:?}" ;;
    --worker-service)  shift; WORKER="${1:?}" ;;
    --revert)          REVERT=true ;;
    -h|--help)         sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                 echo "unknown arg: $1" >&2; exit 1 ;;
  esac; shift
done

if [[ -t 1 ]]; then R=$'\033[1;31m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; Z=$'\033[0m'; else R= G= Y= Z=; fi
ok()   { printf '%s  ✔%s  %s\n' "$G" "$Z" "$*"; }
warn() { printf '%s  ⚠%s  %s\n' "$Y" "$Z" "$*" >&2; }
die()  { printf '%s  ✘%s  %s\n' "$R" "$Z" "$*" >&2; exit 1; }

cd "$DIFY_DIR"
[[ -f docker-compose.yaml || -f docker-compose.yml ]] || die "no docker-compose.yaml here — use --dify-dir"
docker compose version >/dev/null 2>&1 || die "docker compose v2 not available"

OVERRIDE="docker-compose.override.yaml"
BUNDLE="dify-ca-bundle.crt"

# ── revert ────────────────────────────────────────────────────────────────────
if $REVERT; then
  [[ -f "$OVERRIDE" ]] && rm -f "$OVERRIDE" && ok "removed $OVERRIDE"
  [[ -f "$BUNDLE"   ]] && rm -f "$BUNDLE"   && ok "removed $BUNDLE"
  docker compose up -d "$API" "$WORKER"
  ok "Dify recreated without the Kong cert. Done."
  exit 0
fi

# ── pre-flight ────────────────────────────────────────────────────────────────
[[ -f "$CERT" ]] || die "Kong cert not found: $CERT (copy /opt/kong/ssl/kong-proxy.crt here)"
openssl x509 -in "$CERT" -noout >/dev/null 2>&1 || die "$CERT is not a valid PEM certificate"
[[ "$(docker compose ps -q "$API")" ]] || die "service '$API' is not running — start Dify first"
[[ ! -f "$OVERRIDE" ]] || die "$OVERRIDE already exists — remove/merge it manually, then re-run (or --revert)"

# ── 1. extract Dify's REAL CA bundle from inside the container ────────────────
echo "Extracting Dify's CA bundle (certifi) from the '$API' container ..."
CP="$(docker compose exec -T "$API" sh -c 'python -c "import certifi;print(certifi.where())" 2>/dev/null || python3 -c "import certifi;print(certifi.where())"' | tr -d '\r\n')"
[[ -n "$CP" ]] || die "could not locate certifi in the '$API' container"
docker compose exec -T "$API" cat "$CP" > "$BUNDLE"

# ── 2. SAFETY CHECK: the base bundle must contain the full public CA set ──────
BASE_N="$(grep -c 'BEGIN CERTIFICATE' "$BUNDLE" || true)"
if [[ "${BASE_N:-0}" -lt 100 ]]; then
  rm -f "$BUNDLE"
  die "extracted CA bundle has only ${BASE_N:-0} certs (expected 100+). Aborting — this would break TLS to other services."
fi
ok "Base CA bundle OK ($BASE_N certs)"

# ── 3. append the Kong cert ───────────────────────────────────────────────────
printf '\n' >> "$BUNDLE"; cat "$CERT" >> "$BUNDLE"
FINAL_N="$(grep -c 'BEGIN CERTIFICATE' "$BUNDLE" || true)"
[[ "$FINAL_N" -gt "$BASE_N" ]] || { rm -f "$BUNDLE"; die "append failed (count $BASE_N -> $FINAL_N)"; }
ok "Kong cert added ($BASE_N -> $FINAL_N certs)"

# ── 4. write the compose OVERRIDE (additive, never touches the original) ──────
MOUNT="/etc/ssl/dify-ca-bundle.crt"
cat > "$OVERRIDE" <<EOF
# Added by add-kong-cert-to-dify.sh — trusts the SEHC AI Gateway self-signed cert
# in addition to the default CAs. Remove this file (or run --revert) to undo.
services:
  $API:
    volumes:
      - ./$BUNDLE:$MOUNT:ro
    environment:
      REQUESTS_CA_BUNDLE: $MOUNT
      SSL_CERT_FILE: $MOUNT
  $WORKER:
    volumes:
      - ./$BUNDLE:$MOUNT:ro
    environment:
      REQUESTS_CA_BUNDLE: $MOUNT
      SSL_CERT_FILE: $MOUNT
EOF
docker compose config >/dev/null || { rm -f "$OVERRIDE"; die "compose config invalid after override — reverted the override"; }
ok "Wrote $OVERRIDE"

# ── 5. apply ──────────────────────────────────────────────────────────────────
echo "Recreating $API and $WORKER ..."
docker compose up -d "$API" "$WORKER"

# ── 6. TLS test (optional, key-free) ──────────────────────────────────────────
if [[ -n "$GATEWAY" ]]; then
  host="${GATEWAY%%:*}"; port="${GATEWAY##*:}"
  echo "Testing TLS verification to $host:$port from inside '$API' ..."
  docker compose exec -T "$API" sh -c "python - '$host' '$port' 2>/dev/null || python3 - '$host' '$port'" <<'PY' || true
import ssl, socket, sys
host, port = sys.argv[1], int(sys.argv[2])
try:
    ctx = ssl.create_default_context()            # honors SSL_CERT_FILE env
    with socket.create_connection((host, port), timeout=10) as s:
        with ctx.wrap_socket(s, server_hostname=host) as ss:
            print("OK: TLS to %s:%d verified (Kong cert trusted, public CAs intact)" % (host, port))
except ssl.SSLError as e:
    print("FAIL(SSL): %s" % e); sys.exit(1)
except Exception as e:
    print("WARN: couldn't connect (%s) — bundle is in place; verify from the app" % e)
PY
fi

cat <<EOF

${G}Done.${Z} Dify now trusts the gateway cert (and keeps every other CA).
  In Dify, set the model endpoint to:  https://${GATEWAY:-<PCA_IP>:8443}/<route>/v1
  Undo any time:  $0 --revert
EOF
