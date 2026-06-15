#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# reset-password.sh — admin recovery for SEHC AI Gateway.
#
# Resets a user's password and clears their lockout, without needing to log in
# (runs via `docker exec` against the kong-usermgmt container). Use when an admin
# is locked out (too many failed logins) or has forgotten their password.
#
# Usage:
#   sudo ./reset-password.sh <username>                 # prompt for new password + unlock
#   sudo ./reset-password.sh <username> --password PW   # set password non-interactively
#   sudo ./reset-password.sh <username> --admin         # also ensure role = admin
#   sudo ./reset-password.sh <username> --unlock-only   # clear lockout only (no pwd change)
#   sudo ./reset-password.sh --help
#
# Examples:
#   sudo ./reset-password.sh kong                       # reset kong + unlock
#   sudo ./reset-password.sh backupadmin --admin        # create/repair a backup admin
#   sudo ./reset-password.sh kong --unlock-only         # just lift the 15-min lock
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

readonly CONTAINER="kong-usermgmt"
readonly HTPASSWD_FILE="/data/.htpasswd"
readonly USERS_FILE="/data/users.json"
readonly LOCKOUTS_FILE="/data/lockouts.json"

if [[ -t 1 ]]; then
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'; C_RST=$'\033[0m'
else
  C_RED= C_GRN= C_YEL= C_RST=
fi
ok()   { printf '%s  ✔%s  %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s  ⚠%s  %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '%s  ✘%s  %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

# ── parse args ────────────────────────────────────────────────────────────────
USERNAME=""
PASSWORD=""
SET_ADMIN=false
UNLOCK_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --password)    shift; PASSWORD="${1:-}" ;;
    --admin)       SET_ADMIN=true ;;
    --unlock-only) UNLOCK_ONLY=true ;;
    --help|-h)     usage; exit 0 ;;
    -*)            die "unknown flag: $1 (see --help)" ;;
    *)             [[ -z "$USERNAME" ]] && USERNAME="$1" || die "unexpected argument: $1" ;;
  esac
  shift
done

[[ -n "$USERNAME" ]] || { usage; die "no username given"; }

# ── pre-flight ────────────────────────────────────────────────────────────────
command -v docker >/dev/null || die "docker not installed / not in PATH"
docker inspect "$CONTAINER" >/dev/null 2>&1 || die "container '$CONTAINER' not found — is the stack running?"
[[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" == "true" ]] \
  || die "container '$CONTAINER' is not running"

# ── clear lockout (always) ────────────────────────────────────────────────────
clear_lock() {
  docker exec -i "$CONTAINER" python3 - "$USERNAME" "$LOCKOUTS_FILE" <<'PY'
import json, sys
user, path = sys.argv[1], sys.argv[2]
try:
    db = json.load(open(path))
except Exception:
    db = {"users": {}, "ips": {}}
db.setdefault("users", {}).pop(user, None)
# also drop any IP locks so a blocked source IP is freed
db["ips"] = {}
json.dump(db, open(path, "w"))
print("lock cleared")
PY
}

# ── set admin role in users.json ──────────────────────────────────────────────
set_admin_role() {
  docker exec -i "$CONTAINER" python3 - "$USERNAME" "$USERS_FILE" <<'PY'
import json, sys, datetime
user, path = sys.argv[1], sys.argv[2]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
try:
    db = json.load(open(path))
except Exception:
    db = {"version": 1, "users": {}}
db.setdefault("users", {}).setdefault(
    user, {"role": "admin", "email": None, "created_at": now, "updated_at": now}
)
db["users"][user]["role"] = "admin"
db["users"][user]["updated_at"] = now
json.dump(db, open(path, "w"), indent=2)
print("role set to admin")
PY
}

# ── unlock-only path ──────────────────────────────────────────────────────────
if $UNLOCK_ONLY; then
  clear_lock >/dev/null
  ok "Lockout cleared for '$USERNAME' (and any IP locks). They can log in now."
  exit 0
fi

# ── read password if not supplied ─────────────────────────────────────────────
if [[ -z "$PASSWORD" ]]; then
  read -r -s -p "New password for '$USERNAME': " PASSWORD; echo
  read -r -s -p "Confirm password: " CONFIRM; echo
  [[ "$PASSWORD" == "$CONFIRM" ]] || die "passwords do not match"
else
  warn "Password passed on the command line — it may be visible in shell history."
fi
[[ -n "$PASSWORD" ]] || die "password is empty"

# ── apply ─────────────────────────────────────────────────────────────────────
docker exec "$CONTAINER" htpasswd -b "$HTPASSWD_FILE" "$USERNAME" "$PASSWORD" >/dev/null 2>&1 \
  || die "htpasswd failed"
ok "Password reset for '$USERNAME'"

clear_lock >/dev/null
ok "Lockout cleared for '$USERNAME'"

if $SET_ADMIN; then
  set_admin_role >/dev/null
  ok "Role ensured: admin"
fi

printf '\n%sDone.%s  Log in at  http://<host>:8002/  as  %s\n' "$C_GRN" "$C_RST" "$USERNAME"
