#!/usr/bin/env bash
# SEHC AI Gateway — first-install script (idempotent).
# Safe to re-run. Skips steps that are already complete unless override flags are given.
# DO NOT run this on the DEV environment unless you intend a fresh install.
set -euo pipefail

# ── helpers ──────────────────────────────────────────────────────────────────

log()  { printf '\n\033[1;34m[deploy]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✔\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m  %s\n' "$*"; }
die()  { printf '\033[1;31m[FATAL]\033[0m %s\n' "$*" >&2; exit 1; }

RESET_ENV=false
RESET_HTPASSWD=false

for arg in "$@"; do
  case "$arg" in
    --reset-env)      RESET_ENV=true ;;
    --reset-htpasswd) RESET_HTPASSWD=true ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

# ── sanity checks ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[[ -f docker-compose.yml ]] || die "Must be run from the kong project root (docker-compose.yml not found)."
[[ -d usermgmt ]] || die "usermgmt/ directory not found. Is this the correct project root?"

command -v docker >/dev/null 2>&1 || die "docker is not installed or not in PATH."
docker compose version >/dev/null 2>&1 || die "docker compose (v2) not available."

# ── data/ guard ───────────────────────────────────────────────────────────────

if [[ -d ./data && -n "$(ls -A ./data 2>/dev/null)" ]]; then
  die "./data/ already exists and is non-empty. This looks like an existing deployment.
Run upgrade.sh instead. If you really want a fresh install, delete ./data/ manually first."
fi

# ── load pre-built kong-usermgmt image (air-gap safe) ────────────────────────
# Bug 1 fix: load the pre-built image from the tarball (built at release time)
# rather than building from source (which requires internet for apk/pip).
# If images/kong-usermgmt.tar exists alongside this script, load it now.

if [[ -f ./images/kong-usermgmt.tar ]]; then
  log "Loading pre-built kong-usermgmt image from images/kong-usermgmt.tar ..."
  docker load -i ./images/kong-usermgmt.tar
  ok "kong-usermgmt image loaded from tarball."
fi

# ── load other offline images ─────────────────────────────────────────────────

if [[ -d offline-package/images && -n "$(ls offline-package/images/*.tar 2>/dev/null)" ]]; then
  log "Loading offline Docker images from offline-package/images/ ..."
  for tarfile in offline-package/images/*.tar; do
    log "  Loading: $tarfile"
    docker load -i "$tarfile"
  done
  ok "Offline images loaded."
else
  warn "No offline image tarballs found in offline-package/images/. Assuming images are already present or pull is available."
fi

# ── .env ──────────────────────────────────────────────────────────────────────

if [[ -f .env && "$RESET_ENV" == false ]]; then
  warn ".env already exists. Skipping generation (pass --reset-env to regenerate)."
else
  log "Generating .env from template ..."
  cp .env.example .env
  chmod 600 .env

  SESSION_SECRET="$(openssl rand -hex 32)"
  sed -i "s|replace-me-with-a-32-byte-hex-string|${SESSION_SECRET}|g" .env

  # Generate a random KONG_PG_PASSWORD
  KONG_PG_PASSWORD="$(openssl rand -hex 16)"
  sed -i "s|replace-me-with-a-random-string|${KONG_PG_PASSWORD}|g" .env

  # Prompt for SMTP_HOST
  printf '\nSMTP relay hostname or IP [mail.internal]: '
  read -r smtp_input
  smtp_input="${smtp_input:-mail.internal}"
  sed -i "s|^SMTP_HOST=.*|SMTP_HOST=${smtp_input}|" .env

  ok ".env written (SESSION_SECRET and KONG_PG_PASSWORD auto-generated)."
fi

# ── nginx/.htpasswd ──────────────────────────────────────────────────────────

if [[ -f nginx/.htpasswd && "$RESET_HTPASSWD" == false ]]; then
  warn "nginx/.htpasswd already exists. Skipping generation (pass --reset-htpasswd to regenerate)."
else
  log "Creating nginx/.htpasswd ..."

  DEFAULT_PASS="$(openssl rand -hex 16)"
  printf '\nAdmin password for Kong Manager Basic Auth (leave blank to auto-generate): '
  read -r -s admin_pass_input
  printf '\n'
  if [[ -z "$admin_pass_input" ]]; then
    ADMIN_PASS="$DEFAULT_PASS"
    warn "No password provided — auto-generated."
  else
    ADMIN_PASS="$admin_pass_input"
  fi

  # Bug 2 fix: fallback uses the pre-loaded kong-usermgmt image (apache2-utils
  # is already inside it) instead of pulling httpd:2.4-alpine from the internet.
  if command -v htpasswd >/dev/null 2>&1; then
    htpasswd -bc nginx/.htpasswd kong "$ADMIN_PASS"
  else
    warn "htpasswd not on host; using kong-usermgmt image (apache2-utils inside)..."
    docker run --rm \
      -v "$(pwd)/nginx:/work" \
      -w /work \
      --entrypoint htpasswd \
      kong-usermgmt:latest \
      -bc .htpasswd kong "$ADMIN_PASS"
  fi
  chmod 600 nginx/.htpasswd
  ok "nginx/.htpasswd created (user: kong)."
fi

# ── runtime state dirs ────────────────────────────────────────────────────────

log "Ensuring runtime state directories exist ..."
mkdir -p ./data/audit
ok "./data/audit/ ready."

# ── build or verify usermgmt image ───────────────────────────────────────────
# Bug 1 fix: if the pre-built image was loaded from images/kong-usermgmt.tar
# above, skip `docker compose build`. Only build from source if the image is
# not already present (e.g., developer workstation with no tarball).

if docker image inspect kong-usermgmt:latest >/dev/null 2>&1; then
  ok "kong-usermgmt:latest image already present — skipping build."
else
  log "Building kong-usermgmt image from source ..."
  docker compose build kong-usermgmt
  ok "kong-usermgmt image built."
fi

# ── start stack ───────────────────────────────────────────────────────────────

log "Starting stack ..."
docker compose up -d
ok "Stack started."

# ── wait for healthy ──────────────────────────────────────────────────────────

log "Waiting for kong-usermgmt /healthz ..."
for i in $(seq 1 30); do
  if docker exec kong-usermgmt curl -sf http://localhost:5000/healthz >/dev/null 2>&1; then
    ok "kong-usermgmt is healthy."
    break
  fi
  if [[ "$i" -eq 30 ]]; then
    warn "kong-usermgmt did not report healthy after 30s. Check: docker compose logs kong-usermgmt"
  fi
  sleep 2
done

# ── summary ───────────────────────────────────────────────────────────────────

HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
HOST_IP="${HOST_IP:-<host-ip>}"

printf '\n'
printf '══════════════════════════════════════════════════════════\n'
printf '  SEHC AI Gateway — Deploy Complete\n'
printf '══════════════════════════════════════════════════════════\n'
if [[ -n "${ADMIN_PASS:-}" ]]; then
  printf '  Admin user:     kong\n'
  printf '  Admin password: %s\n' "$ADMIN_PASS"
  printf '  !! SAVE THIS — it will not be shown again !!\n\n'
fi
printf '  Kong Manager GUI:  http://%s:8002/\n' "$HOST_IP"
printf '  User Mgmt Portal:  http://%s:8888/\n' "$HOST_IP"
printf '  Kong Proxy:        http://%s:8000/\n' "$HOST_IP"
printf '\n'
printf '  Runbook: docs/DEPLOY.md\n'
printf '══════════════════════════════════════════════════════════\n\n'
