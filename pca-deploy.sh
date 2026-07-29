#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# pca-deploy.sh — Install OR upgrade SEHC AI Gateway on PCA.
#
# Auto-detects the mode:
#   • UPGRADE  if an existing kong container is running (preserves users,
#              passwords, database, audit logs).
#   • FRESH    if no kong container exists (creates /opt/kong, generates
#              SESSION_SECRET, KONG_PG_PASSWORD, random admin password,
#              creates nginx/.htpasswd, brings the full stack up).
#
# Usage:
#   sudo ./pca-deploy.sh kong-deploy-vX.Y.Z.tar.gz
#   sudo ./pca-deploy.sh kong-deploy-vX.Y.Z.tar.gz --install-dir /opt/kong
#   sudo ./pca-deploy.sh --rollback                # restore latest backup
#
# The script is self-contained. Run it from the release directory:
#
#   release/vX.Y.Z/
#     ├── pca-deploy.sh
#     ├── kong-deploy-vX.Y.Z.tar.gz
#     ├── kong-deploy-vX.Y.Z.sha256.txt
#     └── images/
#         ├── kong-oss-3.9.tar
#         ├── postgres-15-alpine.tar
#         └── nginx-alpine.tar
#
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly DEFAULT_INSTALL="/opt/kong"
readonly ADMIN_USER="kong"

# ── output helpers ──────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
  C_BLU=$'\033[1;34m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_RED= C_GRN= C_YEL= C_BLU= C_DIM= C_RST=
fi

log()  { printf '%s[%s]%s %s\n' "$C_BLU" "$SCRIPT_NAME" "$C_RST" "$*"; }
ok()   { printf '%s  ✔%s  %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s  ⚠%s  %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '%s  ✘%s  %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

# ── proxy TLS cert ────────────────────────────────────────────────────────────
# Kong proxy serves HTTPS on :8443 using a default cert. IP-based clients send no
# SNI, so this self-signed cert (SAN = the box IP) is what they receive. Generated
# locally with openssl — no internet, air-gap safe. Idempotent: skips if present.
# Make the cert readable by the NON-root kong container user (uid/gid 1001 in
# kong:3.9). The cert is created by root; a 600 key is unreadable by kong, so Kong
# fails to load TLS and the container never becomes healthy. Prefer group-read by
# the kong gid; fall back to world-read if that gid is unavailable.
_fix_cert_perms() {
  local key="$1" crt="$2"
  if chown root:1001 "$key" "$crt" 2>/dev/null; then
    chmod 640 "$key"; chmod 644 "$crt"
  else
    chmod 644 "$key" "$crt"
  fi
}

ensure_proxy_cert() {
  local dir="$1/ssl"
  local crt="$dir/kong-proxy.crt" key="$dir/kong-proxy.key"
  if [[ -f "$crt" && -f "$key" ]]; then
    ok "Proxy TLS cert already present ($(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | tr -d ' ' | grep -oE 'IPAddress:[0-9.]+' | head -1))"
    _fix_cert_perms "$key" "$crt"   # re-assert perms (repairs an old root-only 600 cert)
    return 0
  fi
  # IP that clients will use to reach :8443. MUST match how clients connect.
  # Explicit --cert-ip wins; otherwise auto-detect (fragile on multi-NIC/Docker hosts).
  local ip="${CERT_IP_OVERRIDE:-}"
  if [[ -z "$ip" ]]; then
    # Skip Docker bridge ranges (172.16-31.x) when picking the primary IP.
    ip=$(hostname -I 2>/dev/null | tr ' ' '\n' \
           | grep -vE '^172\.(1[6-9]|2[0-9]|3[01])\.' | grep -E '^[0-9.]+$' | head -1)
    [[ -n "$ip" ]] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -n "$ip" ]] || ip="127.0.0.1"
    warn "No --cert-ip given; auto-detected $ip for the TLS cert."
    warn "If clients reach this box on a DIFFERENT IP, re-run with: --cert-ip <ip>"
  fi
  log "Generating self-signed proxy TLS cert for $ip (:8443 HTTPS) ..."
  mkdir -p "$dir"
  chmod 755 "$dir"
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$key" -out "$crt" -days 3650 \
    -subj "/CN=$ip/O=SEHC AI Gateway" \
    -addext "subjectAltName=IP:$ip,IP:127.0.0.1" >/dev/null 2>&1 \
    || die "openssl proxy cert generation failed"
  _fix_cert_perms "$key" "$crt"
  ok "Proxy TLS cert created (SAN IP:$ip)"
}

# ── Prometheus plugin ─────────────────────────────────────────────────────────
# Enables the bundled Prometheus plugin (global) so metrics are exposed on the
# Status API (:8100/metrics) for external scraping (e.g. Zabbix). The plugin row
# lives in Postgres, so this only does work on a fresh install; on upgrade it is
# already present and we skip. Idempotent and non-fatal.
enable_prometheus_plugin() {
  local admin="http://localhost:8001"
  local i
  for i in $(seq 1 30); do
    curl -sf "$admin/" >/dev/null 2>&1 && break
    sleep 1
  done
  if curl -sf "$admin/plugins" 2>/dev/null | grep -q '"name":"prometheus"'; then
    ok "Prometheus plugin already enabled"
    return 0
  fi
  log "Enabling Prometheus plugin (global, :8100/metrics) ..."
  if curl -sf -X POST "$admin/plugins" \
       -d name=prometheus \
       -d config.status_code_metrics=true \
       -d config.latency_metrics=true \
       -d config.bandwidth_metrics=true \
       -d config.per_consumer=true >/dev/null 2>&1; then
    ok "Prometheus plugin enabled"
  else
    warn "Could not enable Prometheus plugin — enable it manually via Admin API"
  fi
}

# file-log plugin (global) → JSON access log with client_ip/consumer/service for
# the portal Requests tab. Writes to /kong-reqlog/requests.log (shared volume).
enable_filelog_plugin() {
  local admin="http://localhost:8001"
  local i
  for i in $(seq 1 30); do
    curl -sf "$admin/" >/dev/null 2>&1 && break
    sleep 1
  done
  if curl -sf "$admin/plugins" 2>/dev/null | grep -q '"name":"file-log"'; then
    ok "file-log plugin already enabled"
    return 0
  fi
  log "Enabling file-log plugin (access log for portal Requests tab) ..."
  if curl -sf -X POST "$admin/plugins" \
       -d name=file-log \
       -d config.path=/kong-reqlog/requests.log \
       -d config.reopen=true >/dev/null 2>&1; then
    ok "file-log plugin enabled"
  else
    warn "Could not enable file-log plugin — enable it manually via Admin API"
  fi
}

# Shared request-log dir (Kong writes as uid 1001; auth-proxy reads) + host
# logrotate so the JSON access log cannot fill the disk.
ensure_reqlog() {
  local dir="$1/data/reqlog"
  mkdir -p "$dir"
  chmod 777 "$dir"
  if [ -d /etc/logrotate.d ] && [ -f "$1/deploy/logrotate-kong-requests" ]; then
    sed "s|__REQLOG__|$dir/requests.log|g" "$1/deploy/logrotate-kong-requests" > /etc/logrotate.d/kong-requests 2>/dev/null \
      && ok "logrotate installed for $dir/requests.log" \
      || warn "Could not install logrotate for the request log"
  fi
}

usage() {
  cat <<EOF
Usage:
  sudo ./$SCRIPT_NAME <tarball.tar.gz>                  # auto: install or upgrade
  sudo ./$SCRIPT_NAME <tarball.tar.gz> --install-dir /opt/kong
  sudo ./$SCRIPT_NAME <tarball.tar.gz> --cert-ip <ip>   # IP for the :8443 HTTPS cert
  sudo ./$SCRIPT_NAME --rollback                        # restore last backup
  sudo ./$SCRIPT_NAME --help

  --cert-ip <ip>  IP clients use to reach :8443. Sets the self-signed proxy
                  cert's SAN. If omitted, auto-detected (verify it is correct on
                  multi-NIC / Docker hosts). Ignored if a cert already exists.

Examples:
  sudo ./$SCRIPT_NAME kong-deploy-v1.0.1.tar.gz --cert-ip 10.20.30.40
  sudo ./$SCRIPT_NAME --rollback
EOF
}

# ── arg parsing ──────────────────────────────────────────────────────────────
TARBALL=""
DO_ROLLBACK=false
INSTALL_DIR_OVERRIDE=""
CERT_IP_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rollback)     DO_ROLLBACK=true ;;
    --install-dir)  shift; INSTALL_DIR_OVERRIDE="${1:-}" ;;
    --cert-ip)      shift; CERT_IP_OVERRIDE="${1:-}" ;;
    --help|-h)      usage; exit 0 ;;
    -*)             die "unknown flag: $1 (see --help)" ;;
    *)              TARBALL="$1" ;;
  esac
  shift
done

# ── pre-flight ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "must be run as root (try: sudo $0 $*)"
command -v docker         >/dev/null || die "docker not installed"
docker compose version    >/dev/null 2>&1 || die "docker compose v2 not installed"
command -v openssl        >/dev/null || die "openssl not installed"
command -v sha256sum      >/dev/null || die "sha256sum not installed"

SCRIPT_DIR=$(dirname "$(realpath "$0")")

# ── detect mode ──────────────────────────────────────────────────────────────
EXISTING_INSTALL=""
if docker inspect kong >/dev/null 2>&1; then
  EXISTING_INSTALL=$(docker inspect kong \
    --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' \
    2>/dev/null || true)
fi

if $DO_ROLLBACK; then
  [[ -n "$EXISTING_INSTALL" ]] || die "rollback needs an existing install"
  INSTALL="$EXISTING_INSTALL"
  MODE="rollback"
elif [[ -n "$EXISTING_INSTALL" && -f "$EXISTING_INSTALL/docker-compose.yml" ]]; then
  INSTALL="$EXISTING_INSTALL"
  MODE="upgrade"
else
  INSTALL="${INSTALL_DIR_OVERRIDE:-$DEFAULT_INSTALL}"
  if [[ -d "$INSTALL/data" ]] && [[ -n "$(ls -A "$INSTALL/data" 2>/dev/null)" ]]; then
    die "fresh install but $INSTALL/data already has runtime state.
       If you want to upgrade, just re-run without --install-dir.
       If you want to overwrite, manually remove $INSTALL/data first."
  fi
  MODE="fresh"
fi

# ── banner ───────────────────────────────────────────────────────────────────
printf '\n%s══════════════════════════════════════════════════════════%s\n' "$C_BLU" "$C_RST"
printf '  %sSEHC AI Gateway%s — PCA deploy\n' "$C_GRN" "$C_RST"
printf '  Mode:        %s%s%s\n' "$C_YEL" "$MODE" "$C_RST"
printf '  Install dir: %s%s%s\n' "$C_DIM" "$INSTALL" "$C_RST"
[[ "$MODE" != "rollback" ]] && printf '  Tarball:     %s%s%s\n' "$C_DIM" "$TARBALL" "$C_RST"
printf '%s══════════════════════════════════════════════════════════%s\n\n' "$C_BLU" "$C_RST"

read -r -p "Continue? [y/N] " confirm
[[ "$confirm" =~ ^[yY]$ ]] || die "cancelled"

# ═══════════════════════════════════════════════════════════════════════════
# ROLLBACK MODE
# ═══════════════════════════════════════════════════════════════════════════
if $DO_ROLLBACK; then
  log "Looking for latest backup ..."
  shopt -s nullglob
  BACKUPS=( "$INSTALL"/backups/pre-upgrade-*/ )
  shopt -u nullglob
  (( ${#BACKUPS[@]} > 0 )) || die "no backups in $INSTALL/backups/"
  LATEST=$(printf '%s\n' "${BACKUPS[@]}" | sort -r | head -1)
  LATEST="${LATEST%/}"
  log "Restoring from: $C_DIM$LATEST$C_RST"
  read -r -p "  Are you sure? [y/N] " c
  [[ "$c" =~ ^[yY]$ ]] || die "rollback cancelled"

  cd "$INSTALL"
  docker compose down || warn "compose down failed (continuing)"

  [[ -f "$LATEST/config.tar.gz" ]] && tar xzf "$LATEST/config.tar.gz" -C "$INSTALL" && ok "config restored"
  [[ -f "$LATEST/dot-env.bak" ]] && cp "$LATEST/dot-env.bak" "$INSTALL/.env" && chmod 600 "$INSTALL/.env" && ok ".env restored"

  if [[ -f "$LATEST/pg_data.sql.gz" ]]; then
    log "Restoring Postgres ..."
    docker compose up -d kong-database >/dev/null
    for i in {1..30}; do
      docker exec kong-database pg_isready -U kong >/dev/null 2>&1 && break
      sleep 1
    done
    gunzip -c "$LATEST/pg_data.sql.gz" \
      | docker exec -i kong-database psql -U kong -d kong >/dev/null \
      || die "pg restore failed"
    ok "Postgres restored"
  fi

  ensure_proxy_cert "$INSTALL"
  docker compose up -d
  sleep 10
  docker compose ps
  ok "Rollback complete."
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# COMMON: validate tarball + checksum + load base images
# ═══════════════════════════════════════════════════════════════════════════
[[ -n "$TARBALL" ]] || { usage; die "no tarball given"; }
[[ -f "$TARBALL" ]] || die "tarball not found: $TARBALL"
TARBALL=$(realpath "$TARBALL")

# Locate sha256 file — accept multiple naming conventions
SHA256=""
for candidate in \
  "${TARBALL}.sha256.txt" \
  "${TARBALL%.tar.gz}.sha256.txt" \
  "${TARBALL}.sha256" \
  "${TARBALL%.tar.gz}.sha256"; do
  if [[ -f "$candidate" ]]; then SHA256="$candidate"; break; fi
done
[[ -n "$SHA256" ]] || die "no .sha256(.txt) file found next to $TARBALL"

log "Verifying SHA256 ..."
EXPECTED=$(awk '{print $1; exit}' "$SHA256")
ACTUAL=$(sha256sum "$TARBALL" | awk '{print $1}')
[[ "$EXPECTED" == "$ACTUAL" ]] || die "checksum FAILED — re-transfer the tarball"
ok "Checksum OK"

# Load base Docker images from sibling images/ if present and missing on host
if [[ -d "$SCRIPT_DIR/images" ]]; then
  log "Checking base Docker images ..."
  shopt -s nullglob
  for img_tar in "$SCRIPT_DIR/images"/*.tar; do
    fname=$(basename "$img_tar")
    [[ "$fname" == "kong-usermgmt.tar" ]] && continue
    case "$fname" in
      kong-oss-3.9.tar)        IMG="kong:3.9" ;;
      postgres-15-alpine.tar)  IMG="postgres:15-alpine" ;;
      nginx-alpine.tar)        IMG="nginx:alpine" ;;
      *)                       IMG="" ;;
    esac
    if [[ -n "$IMG" ]] && docker image inspect "$IMG" >/dev/null 2>&1; then
      ok "$IMG already present"
    else
      log "  Loading $fname ..."
      docker load -i "$img_tar" >/dev/null && ok "Loaded $fname"
    fi
  done
  shopt -u nullglob
fi

# ═══════════════════════════════════════════════════════════════════════════
# FRESH INSTALL
# ═══════════════════════════════════════════════════════════════════════════
if [[ "$MODE" == "fresh" ]]; then
  log "Fresh install at $INSTALL ..."
  mkdir -p "$INSTALL"
  TMPDIR=$(mktemp -d); trap 'rm -rf "$TMPDIR"' EXIT
  tar xzf "$TARBALL" -C "$TMPDIR"
  INNER=$(find "$TMPDIR" -maxdepth 1 -mindepth 1 -type d | head -1)
  cp -a "$INNER/." "$INSTALL/"
  cd "$INSTALL"
  ok "Bundle extracted"

  # Load kong-usermgmt image from inside the extracted bundle
  if [[ -f "$INSTALL/images/kong-usermgmt.tar" ]]; then
    log "Loading kong-usermgmt image ..."
    docker load -i "$INSTALL/images/kong-usermgmt.tar" >/dev/null
    ok "kong-usermgmt image loaded"
  fi

  # Generate secrets
  log "Generating .env with random secrets ..."
  SESSION_SECRET=$(openssl rand -hex 32)
  KONG_PG_PASSWORD=$(openssl rand -hex 16)
  ADMIN_PASS=$(openssl rand -hex 12)

  cat > "$INSTALL/.env" <<EOF
SESSION_SECRET=$SESSION_SECRET
KONG_PG_PASSWORD=$KONG_PG_PASSWORD
SMTP_HOST=mail.invalid
SMTP_USER=
SMTP_PASS=
MFA_ENFORCED=false
EOF
  chmod 600 "$INSTALL/.env"
  ok ".env created"

  # Create htpasswd
  log "Creating nginx/.htpasswd for admin user '$ADMIN_USER' ..."
  if command -v htpasswd >/dev/null 2>&1; then
    htpasswd -bc "$INSTALL/nginx/.htpasswd" "$ADMIN_USER" "$ADMIN_PASS"
  else
    docker run --rm -v "$INSTALL/nginx:/work" -w /work \
      --entrypoint htpasswd kong-usermgmt:latest \
      -bc .htpasswd "$ADMIN_USER" "$ADMIN_PASS"
  fi
  chmod 600 "$INSTALL/nginx/.htpasswd"
  ok "nginx/.htpasswd created"

  # Create runtime dirs
  mkdir -p "$INSTALL/data/audit" "$INSTALL/backups"
  ok "data/ + backups/ directories created"

  # Shared request-log dir + logrotate (portal Requests tab)
  ensure_reqlog "$INSTALL"

  # Self-signed proxy TLS cert for :8443 HTTPS
  ensure_proxy_cert "$INSTALL"

  # Make scripts executable
  chmod +x "$INSTALL"/*.sh 2>/dev/null || true
  chmod +x "$INSTALL"/scripts/*.sh 2>/dev/null || true

  # Bring up the stack
  log "Starting all containers ..."
  docker compose up -d

  log "Waiting for kong-usermgmt healthz ..."
  for i in {1..30}; do
    if curl -sf http://localhost:8888/healthz >/dev/null 2>&1; then
      ok "kong-usermgmt healthy"
      break
    fi
    sleep 1
  done

  # Enable Prometheus metrics for external monitoring (Zabbix/Grafana)
  enable_prometheus_plugin
  # Enable file-log access log for the portal Requests tab
  enable_filelog_plugin

  # Save admin password to a guarded file
  PASS_FILE="$INSTALL/.first-install-admin-password.txt"
  printf 'Admin user: %s\nAdmin pass: %s\nInstalled:  %s\n' \
    "$ADMIN_USER" "$ADMIN_PASS" "$(date -u +%FT%TZ)" > "$PASS_FILE"
  chmod 600 "$PASS_FILE"

  IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  cat <<EOF

${C_GRN}══════════════════════════════════════════════════════════${C_RST}
  ${C_GRN}Fresh install complete${C_RST}

  Admin user:  ${C_YEL}$ADMIN_USER${C_RST}
  Admin pass:  ${C_YEL}$ADMIN_PASS${C_RST}
  ${C_RED}SAVE THIS PASSWORD — it is shown ONCE.${C_RST}
  (Also written to: $PASS_FILE — chmod 600)

  Login:       http://${IP:-<pca-ip>}:8002/
  User mgmt:   http://${IP:-<pca-ip>}:8888/
  Audit log:   http://${IP:-<pca-ip>}:8002/logs/

  Next steps:
    1. Log in and CHANGE the password.
    2. Set admin email (User Mgmt page).
    3. Configure SMTP relay (User Mgmt → SMTP Settings).
    4. Enable MFA per-user via the toggle on the user list.
${C_GRN}══════════════════════════════════════════════════════════${C_RST}
EOF
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# UPGRADE MODE
# ═══════════════════════════════════════════════════════════════════════════
log "Upgrading existing install at $INSTALL ..."

# Pre-upgrade snapshot
TS=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_DIR="$INSTALL/backups/pre-upgrade-$TS"
mkdir -p "$BACKUP_DIR"

log "Backup → $BACKUP_DIR"
tar czf "$BACKUP_DIR/config.tar.gz" -C "$INSTALL" \
  --exclude='data' --exclude='backups' --exclude='release' \
  --exclude='offline-package' --exclude='*.tar' --exclude='*.tar.gz' \
  . 2>/dev/null || warn "some files skipped"
ok "config.tar.gz ($(du -h "$BACKUP_DIR/config.tar.gz" | cut -f1))"

if [[ -f "$INSTALL/.env" ]]; then
  cp "$INSTALL/.env" "$BACKUP_DIR/dot-env.bak"
  chmod 600 "$BACKUP_DIR/dot-env.bak"
  ok ".env saved"
fi

log "Dumping Postgres via pg_dump ..."
if docker exec kong-database pg_dump -U kong --clean --if-exists kong \
     > "$BACKUP_DIR/pg_data.sql" 2>"$BACKUP_DIR/pg_dump.err"; then
  gzip "$BACKUP_DIR/pg_data.sql"
  rm -f "$BACKUP_DIR/pg_dump.err"
  ok "pg_data.sql.gz ($(du -h "$BACKUP_DIR/pg_data.sql.gz" | cut -f1))"
else
  warn "pg_dump failed — Postgres volume itself is unchanged by upgrade, continuing"
fi

if [[ -d "$INSTALL/data" ]]; then
  tar czf "$BACKUP_DIR/data.tar.gz" -C "$INSTALL" data \
    --exclude='data/*.lock' --exclude='data/audit/access-current.jsonl' 2>/dev/null \
    || warn "could not back up data/"
  [[ -f "$BACKUP_DIR/data.tar.gz" ]] && ok "data.tar.gz ($(du -h "$BACKUP_DIR/data.tar.gz" | cut -f1))"
fi

# Extract new bundle
log "Extracting new bundle (preserves .env and nginx/.htpasswd) ..."
TMPDIR=$(mktemp -d); trap 'rm -rf "$TMPDIR"' EXIT
tar xzf "$TARBALL" -C "$TMPDIR"
INNER=$(find "$TMPDIR" -maxdepth 1 -mindepth 1 -type d | head -1)
( cd "$INNER" && find . -type f -print0 ) | while IFS= read -r -d '' rel; do
  rel="${rel#./}"
  case "$rel" in
    .env|nginx/.htpasswd|offline-package/nginx/.htpasswd) continue ;;
  esac
  target="$INSTALL/$rel"
  mkdir -p "$(dirname "$target")"
  cp -f "$INNER/$rel" "$target"
done
ok "Bundle extracted"

# Migrate .env if missing
if [[ ! -f "$INSTALL/.env" ]]; then
  log "Creating .env (v1.0.0 → v1.0.1 migration) ..."
  cat > "$INSTALL/.env" <<EOF
KONG_PG_PASSWORD=kong_pass
SESSION_SECRET=$(openssl rand -hex 32)
SMTP_HOST=mail.invalid
SMTP_USER=
SMTP_PASS=
MFA_ENFORCED=false
EOF
  chmod 600 "$INSTALL/.env"
  ok ".env created with KONG_PG_PASSWORD=kong_pass"
elif ! grep -q '^KONG_PG_PASSWORD=' "$INSTALL/.env"; then
  warn ".env missing KONG_PG_PASSWORD — appending the legacy default"
  echo "KONG_PG_PASSWORD=kong_pass" >> "$INSTALL/.env"
fi

# Load kong-usermgmt image from extracted bundle
if [[ -f "$INSTALL/images/kong-usermgmt.tar" ]]; then
  log "Loading new kong-usermgmt image ..."
  docker load -i "$INSTALL/images/kong-usermgmt.tar" >/dev/null
  ok "kong-usermgmt image loaded"
fi

chmod +x "$INSTALL"/*.sh 2>/dev/null || true
chmod +x "$INSTALL"/scripts/*.sh 2>/dev/null || true

# Self-signed proxy TLS cert for :8443 HTTPS (no-op if already generated)
ensure_proxy_cert "$INSTALL"

# Shared request-log dir + logrotate (must exist before the compose mount)
ensure_reqlog "$INSTALL"

# Recreate affected services
log "Recreating kong-usermgmt and kong-auth-proxy ..."
cd "$INSTALL"
docker compose up -d --force-recreate kong-usermgmt kong-auth-proxy
docker compose up -d   # pick up any other compose-level changes

# Health check
log "Waiting for healthz ..."
for i in {1..30}; do
  if curl -sf http://localhost:8888/healthz >/dev/null 2>&1; then
    ok "kong-usermgmt healthy"
    break
  fi
  sleep 1
done

# Ensure Prometheus metrics stay enabled (no-op if already in DB)
enable_prometheus_plugin
# Ensure file-log access log stays enabled (no-op if already in DB)
enable_filelog_plugin

# Quick smoke test
if curl -sf http://localhost:8002/auth/login | grep -q "SEHC AI GATEWAY"; then
  ok "Login page rebrand visible"
else
  warn "rebrand check failed — inspect 'docker compose logs kong-auth-proxy'"
fi

docker compose ps

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
cat <<EOF

${C_GRN}══════════════════════════════════════════════════════════${C_RST}
  ${C_GRN}Upgrade complete${C_RST}

  Backup:      ${C_DIM}$BACKUP_DIR${C_RST}
  Login:       http://${IP:-<pca-ip>}:8002/

  Existing users + passwords + Postgres data preserved.
  New features available:
    • SMTP config GUI (User Mgmt → SMTP Settings)
    • Per-user MFA toggle (button on each user row)
    • Audit log viewer (http://${IP:-<pca-ip>}:8002/logs/)
    • Server-side session revocation on logout

  Rollback if needed:  sudo $0 --rollback
${C_GRN}══════════════════════════════════════════════════════════${C_RST}
EOF
