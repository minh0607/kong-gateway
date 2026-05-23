#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# pca-upgrade.sh — One-shot PCA upgrade from a release tarball.
#
# Designed for the air-gapped PCA box: copy this script + the release tarball
# (kong-deploy-vX.Y.Z.tar.gz) + its .sha256.txt to PCA, then:
#
#   sudo ./pca-upgrade.sh kong-deploy-vX.Y.Z.tar.gz
#
# The script does:
#   1. Verify the tarball SHA256.
#   2. Auto-detect the existing Kong install directory.
#   3. Snapshot the current config + Postgres data to ./backups/pre-<ts>/.
#   4. Extract the new bundle over the install dir (preserving nginx/.htpasswd
#      and the Postgres named volume).
#   5. Create or migrate .env (KONG_PG_PASSWORD=kong_pass to preserve the
#      existing DB password from the original offline-package install).
#   6. Run upgrade.sh --tarball-only.
#   7. Health-check the result; on failure, suggest rollback.
#
# Rollback to the latest backup:
#   sudo ./pca-upgrade.sh --rollback
#
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"

# ─── output helpers ──────────────────────────────────────────────────────────
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

usage() {
  cat <<EOF
Usage:
  sudo ./$SCRIPT_NAME <tarball.tar.gz>             # upgrade
  sudo ./$SCRIPT_NAME --rollback                   # restore last backup
  sudo ./$SCRIPT_NAME --help

Examples:
  sudo ./$SCRIPT_NAME kong-deploy-v1.0.1.tar.gz
  sudo ./$SCRIPT_NAME --rollback
EOF
}

# ─── arg parsing ─────────────────────────────────────────────────────────────
DO_ROLLBACK=false
TARBALL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rollback) DO_ROLLBACK=true ;;
    --help|-h)  usage; exit 0 ;;
    -*)         die "unknown flag: $1 (see --help)" ;;
    *)          TARBALL="$1" ;;
  esac
  shift
done

# ─── pre-flight ──────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "must be run as root (try: sudo $0 $*)"
command -v docker >/dev/null    || die "docker not installed"
docker compose version >/dev/null 2>&1 || die "docker compose v2 not installed"
command -v openssl >/dev/null   || die "openssl not installed"
command -v sha256sum >/dev/null || die "sha256sum not installed"

# ─── locate install dir ──────────────────────────────────────────────────────
log "Locating existing Kong install ..."
INSTALL=""
if docker inspect kong >/dev/null 2>&1; then
  INSTALL=$(docker inspect kong \
    --format '{{ index .Config.Labels "com.docker.compose.project.working_dir"}}' \
    2>/dev/null || true)
fi
[[ -n "$INSTALL" && -d "$INSTALL" ]] \
  || die "could not auto-detect install dir (is the 'kong' container running?)"
[[ -f "$INSTALL/docker-compose.yml" ]] \
  || die "$INSTALL has no docker-compose.yml — wrong dir?"
ok "Install dir: $INSTALL"

# ─── rollback mode ───────────────────────────────────────────────────────────
if $DO_ROLLBACK; then
  log "Rollback requested — looking for latest backup ..."
  shopt -s nullglob
  BACKUPS=( "$INSTALL"/backups/pre-upgrade-*/ )
  shopt -u nullglob
  (( ${#BACKUPS[@]} > 0 )) || die "no backups found in $INSTALL/backups/"
  # newest first
  IFS=$'\n' read -r -d '' -a SORTED < <(printf '%s\n' "${BACKUPS[@]}" | sort -r && printf '\0')
  LATEST="${SORTED[0]%/}"
  log "Will restore from: $C_DIM$LATEST$C_RST"
  read -r -p "  Proceed with rollback? [y/N] " confirm
  [[ "$confirm" =~ ^[yY]$ ]] || die "rollback cancelled"

  cd "$INSTALL"
  docker compose down || warn "compose down had non-zero exit (continuing)"

  [[ -f "$LATEST/config.tar.gz" ]] \
    && tar xzf "$LATEST/config.tar.gz" -C "$INSTALL" && ok "config restored"
  [[ -f "$LATEST/dot-env.bak" ]] \
    && cp "$LATEST/dot-env.bak" "$INSTALL/.env" && chmod 600 "$INSTALL/.env" \
    && ok ".env restored"

  log "Restoring Postgres volume from $LATEST/pg_data.tar.gz ..."
  docker volume rm kong_pg_data >/dev/null 2>&1 || true
  docker volume create kong_pg_data >/dev/null
  docker run --rm -v kong_pg_data:/data -v "$LATEST":/bak alpine \
    sh -c 'tar xzf /bak/pg_data.tar.gz -C /data' || die "pg_data restore failed"
  ok "Postgres volume restored"

  docker compose up -d
  log "Waiting 10s for containers ..."
  sleep 10
  docker compose ps
  ok "Rollback complete."
  exit 0
fi

# ─── tarball mode (upgrade) ──────────────────────────────────────────────────
[[ -n "$TARBALL" ]] || { usage; die "no tarball given"; }
[[ -f "$TARBALL" ]] || die "tarball not found: $TARBALL"
TARBALL=$(realpath "$TARBALL")
SHA256="${TARBALL}.sha256.txt"
[[ -f "$SHA256" ]] || die "sha256 file not next to tarball: $SHA256"

# 1. Verify checksum
log "Verifying SHA256 ..."
( cd "$(dirname "$TARBALL")" && sha256sum -c "$(basename "$SHA256")" ) >/dev/null \
  || die "checksum FAILED — re-transfer the tarball"
ok "Checksum OK"

# 2. Pre-upgrade health snapshot
log "Pre-upgrade health check ..."
RUNNING=$(docker compose -f "$INSTALL/docker-compose.yml" ps --services --status running 2>/dev/null | wc -l)
log "  running services: $RUNNING"
if (( RUNNING < 1 )); then
  warn "no services currently running — this is a recovery upgrade, not a routine one"
  read -r -p "  Continue anyway? [y/N] " confirm
  [[ "$confirm" =~ ^[yY]$ ]] || die "upgrade cancelled"
fi

# 3. Backup
TS=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_DIR="$INSTALL/backups/pre-upgrade-$TS"
log "Creating backup at $BACKUP_DIR ..."
mkdir -p "$BACKUP_DIR"

# 3a. Config files (everything but secrets-and-state)
tar czf "$BACKUP_DIR/config.tar.gz" -C "$INSTALL" \
  --exclude='data' --exclude='backups' --exclude='release' \
  --exclude='offline-package' --exclude='node_modules' \
  --exclude='*.tar' --exclude='*.tar.gz' \
  . 2>/dev/null || warn "some config files skipped during backup"
ok "config.tar.gz ($(du -h "$BACKUP_DIR/config.tar.gz" | cut -f1))"

# 3b. .env separately for easy restore
if [[ -f "$INSTALL/.env" ]]; then
  cp "$INSTALL/.env" "$BACKUP_DIR/dot-env.bak"
  chmod 600 "$BACKUP_DIR/dot-env.bak"
  ok ".env saved"
fi

# 3c. Postgres named volume
log "Snapshotting kong_pg_data volume ..."
docker run --rm -v kong_pg_data:/data -v "$BACKUP_DIR":/bak alpine \
  sh -c 'cd /data && tar czf /bak/pg_data.tar.gz .' \
  || die "pg_data backup failed — aborting (nothing changed yet)"
ok "pg_data.tar.gz ($(du -h "$BACKUP_DIR/pg_data.tar.gz" | cut -f1))"

# 3d. /data runtime state if present (might not exist on first upgrade)
if [[ -d "$INSTALL/data" ]]; then
  tar czf "$BACKUP_DIR/data.tar.gz" -C "$INSTALL" data \
    --exclude='data/*.lock' --exclude='data/audit/access-current.jsonl' 2>/dev/null \
    || warn "could not back up /data"
  [[ -f "$BACKUP_DIR/data.tar.gz" ]] && ok "data.tar.gz ($(du -h "$BACKUP_DIR/data.tar.gz" | cut -f1))"
fi

log "All backups saved to ${C_DIM}${BACKUP_DIR}${C_RST}"

# 4. Extract new bundle
log "Extracting $(basename "$TARBALL") into $INSTALL ..."
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
tar xzf "$TARBALL" -C "$TMPDIR"
INNER=$(find "$TMPDIR" -maxdepth 1 -mindepth 1 -type d | head -1)
[[ -d "$INNER" ]] || die "tarball has unexpected layout"
# Sync files except secrets — leave .env, nginx/.htpasswd alone if they exist
( cd "$INNER" && find . -type f -print0 ) | while IFS= read -r -d '' rel; do
  rel="${rel#./}"
  # Skip files we never overwrite on PCA:
  case "$rel" in
    .env|nginx/.htpasswd|offline-package/nginx/.htpasswd) continue ;;
  esac
  target="$INSTALL/$rel"
  mkdir -p "$(dirname "$target")"
  cp -f "$INNER/$rel" "$target"
done
ok "Bundle extracted"

# 5. Migrate .env if missing
if [[ ! -f "$INSTALL/.env" ]]; then
  log "Creating .env (migration from pre-v1.0.1 install) ..."
  cat > "$INSTALL/.env" <<EOF
# Preserves access to the existing Postgres data created by the original
# kong-offline-package install. DO NOT change unless you intend to lose
# all Kong configuration.
KONG_PG_PASSWORD=kong_pass

# Generated once for this install.
SESSION_SECRET=$(openssl rand -hex 32)

# Internal SMTP relay (used for MFA codes). Override via the admin GUI
# SMTP Settings card after first login.
SMTP_HOST=mail.invalid
SMTP_USER=
SMTP_PASS=

# Global MFA enforcement. Default off — operators enable per-user via the
# admin GUI MFA toggle. Set to "true" only as a compliance kill-switch.
MFA_ENFORCED=false
EOF
  chmod 600 "$INSTALL/.env"
  ok ".env created with KONG_PG_PASSWORD=kong_pass (preserves existing DB)"
else
  log ".env already exists — checking it has KONG_PG_PASSWORD ..."
  if ! grep -q '^KONG_PG_PASSWORD=' "$INSTALL/.env"; then
    warn ".env does NOT contain KONG_PG_PASSWORD — Kong won't reach Postgres"
    warn "Appending: KONG_PG_PASSWORD=kong_pass (the legacy default)"
    echo "KONG_PG_PASSWORD=kong_pass" >> "$INSTALL/.env"
  fi
  ok ".env preserved"
fi

# 6. Make scripts executable
chmod +x "$INSTALL"/{deploy,upgrade,pca-upgrade}.sh 2>/dev/null || true
chmod +x "$INSTALL"/scripts/*.sh 2>/dev/null || true

# 7. Hand off to upgrade.sh
log "Running upgrade.sh --tarball-only ..."
cd "$INSTALL"
if ./upgrade.sh --tarball-only; then
  ok "upgrade.sh completed"
else
  die "upgrade.sh failed — rollback: sudo $0 --rollback"
fi

# 8. Post-upgrade verification
log "Verifying ..."
sleep 5
HEALTH=$(curl -sf http://localhost:8002/auth/login | grep -c "SEHC AI GATEWAY" || true)
if (( HEALTH > 0 )); then
  ok "login page rebrand visible — services responding"
else
  warn "rebrand string not detected — check 'docker compose logs' before declaring success"
fi

docker compose ps

cat <<EOF

${C_GRN}══════════════════════════════════════════════════════════${C_RST}
  ${C_GRN}Upgrade complete${C_RST}
  Backup:    ${C_DIM}${BACKUP_DIR}${C_RST}
  Login:     http://$(hostname -I 2>/dev/null | awk '{print $1}'):8002/

  Next steps:
   1. Log in as your existing kong user (password unchanged).
   2. Set your email via the user-management page.
   3. Configure SMTP via the SMTP Settings card.
   4. Enable MFA per-user with the MFA toggle.

  Rollback if needed:  sudo $0 --rollback
${C_GRN}══════════════════════════════════════════════════════════${C_RST}
EOF
