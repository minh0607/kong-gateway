#!/usr/bin/env bash
# SEHC AI Gateway — upgrade script.
# Run from the project root after extracting a new release tarball.
# Backs up ./data/ before touching anything. Does NOT modify .env or nginx/.htpasswd.
set -euo pipefail

# ── helpers ──────────────────────────────────────────────────────────────────

log()  { printf '\n\033[1;34m[upgrade]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✔\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m  %s\n' "$*"; }
die()  { printf '\033[1;31m[FATAL]\033[0m %s\n' "$*" >&2; exit 1; }

# ── sanity checks ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[[ -f docker-compose.yml ]] || die "Must be run from the kong project root (docker-compose.yml not found)."
[[ -d usermgmt ]]           || die "usermgmt/ directory not found. Is this the correct project root?"
[[ -f .env ]]               || die ".env not found. Run deploy.sh first."
[[ -f nginx/.htpasswd ]]    || die "nginx/.htpasswd not found. Run deploy.sh first."

command -v docker >/dev/null 2>&1 || die "docker is not installed or not in PATH."
docker compose version >/dev/null 2>&1 || die "docker compose (v2) not available."
command -v git >/dev/null 2>&1 || die "git is not installed."

# ── backup ./data/ ────────────────────────────────────────────────────────────

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="./backups/${TIMESTAMP}"
BACKUP_TARBALL="${BACKUP_DIR}/data.tar.gz"

log "Taking snapshot of ./data/ → ${BACKUP_TARBALL} ..."
mkdir -p "$BACKUP_DIR"
tar czf "$BACKUP_TARBALL" \
  --exclude='./data/*.lock' \
  --exclude='./data/audit/access-current.jsonl' \
  ./data 2>/dev/null || warn "Some files were skipped during backup (likely open .lock files)."
ok "Backup written: ${BACKUP_TARBALL}"

# ── show what's incoming ─────────────────────────────────────────────────────

log "Fetching latest from origin ..."
git fetch --tags origin

INCOMING="$(git log HEAD..origin/master --oneline | head -20 || true)"
if [[ -z "$INCOMING" ]]; then
  ok "Already up to date with origin/master. Nothing to upgrade."
  exit 0
fi

printf '\nIncoming changes:\n%s\n\n' "$INCOMING"

# ── confirm ───────────────────────────────────────────────────────────────────

read -r -p "Proceed with upgrade? [y/N] " confirm
[[ "${confirm,,}" == "y" ]] || { warn "Upgrade cancelled."; exit 0; }

# ── pull ──────────────────────────────────────────────────────────────────────

log "Pulling from origin/master (fast-forward only) ..."
git pull --ff-only origin master || die "git pull failed. The branch has diverged — reconcile manually before upgrading."

# ── detect what changed ───────────────────────────────────────────────────────

CHANGED="$(git diff HEAD@{1} --name-only 2>/dev/null || true)"

REBUILD_USERMGMT=false
RESTART_PROXY=false
REUP_COMPOSE=false

if echo "$CHANGED" | grep -qE '^usermgmt/(Dockerfile|.*\.py|static/)'; then
  REBUILD_USERMGMT=true
fi

if echo "$CHANGED" | grep -qE '^nginx/(default\.conf|portal\.html)$'; then
  RESTART_PROXY=true
fi

if echo "$CHANGED" | grep -q '^docker-compose\.yml$'; then
  REUP_COMPOSE=true
fi

# ── apply changes ─────────────────────────────────────────────────────────────

REBUILT=""
RESTARTED=""

if [[ "$REBUILD_USERMGMT" == true ]]; then
  log "usermgmt source changed — rebuilding kong-usermgmt image ..."
  docker compose build kong-usermgmt
  docker compose up -d --force-recreate kong-usermgmt
  REBUILT="kong-usermgmt"
  ok "kong-usermgmt rebuilt and recreated."
fi

if [[ "$RESTART_PROXY" == true && "$REUP_COMPOSE" == false ]]; then
  log "nginx config changed — restarting kong-auth-proxy ..."
  docker compose restart kong-auth-proxy
  RESTARTED="${RESTARTED:+$RESTARTED, }kong-auth-proxy"
  ok "kong-auth-proxy restarted."
fi

if [[ "$REUP_COMPOSE" == true ]]; then
  log "docker-compose.yml changed — running docker compose up -d ..."
  docker compose up -d
  RESTARTED="${RESTARTED:+$RESTARTED, }(all via compose up)"
  ok "Compose stack updated."
fi

if [[ "$REBUILD_USERMGMT" == false && "$RESTART_PROXY" == false && "$REUP_COMPOSE" == false ]]; then
  warn "No service-affecting files changed. Stack left as-is."
fi

# ── wait for healthz ──────────────────────────────────────────────────────────

log "Waiting for kong-usermgmt /healthz ..."
for i in $(seq 1 30); do
  if docker exec kong-usermgmt curl -sf http://localhost:5000/healthz >/dev/null 2>&1; then
    ok "kong-usermgmt is healthy."
    break
  fi
  if [[ "$i" -eq 30 ]]; then
    warn "kong-usermgmt /healthz did not respond after 30s. Check: docker compose logs kong-usermgmt"
  fi
  sleep 2
done

# ── summary ───────────────────────────────────────────────────────────────────

printf '\n'
printf '══════════════════════════════════════════════════════════\n'
printf '  SEHC AI Gateway — Upgrade Complete\n'
printf '══════════════════════════════════════════════════════════\n'
printf '  Backup:    %s\n' "$BACKUP_TARBALL"
[[ -n "$REBUILT" ]]   && printf '  Rebuilt:   %s\n' "$REBUILT"
[[ -n "$RESTARTED" ]] && printf '  Restarted: %s\n' "$RESTARTED"
printf '══════════════════════════════════════════════════════════\n\n'
