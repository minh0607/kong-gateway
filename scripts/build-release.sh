#!/usr/bin/env bash
# SEHC AI Gateway — build a release tarball for distribution.
# Output: release/v<VERSION>/kong-deploy-v<VERSION>.tar.gz  + sha256.txt
#
# Usage: scripts/build-release.sh
#
# The kong-usermgmt image is built locally and embedded in the tarball as
# images/kong-usermgmt.tar so deployments are fully self-contained (air-gap safe).
# Base images (kong:3.9, postgres:15-alpine, nginx:alpine) are NOT shipped —
# they are assumed to be present on the target host from the original offline install.
#
# Safe to run on DEV — creates files only, never touches the running stack.
set -euo pipefail

# ── helpers ──────────────────────────────────────────────────────────────────

log()  { printf '\n\033[1;34m[build-release]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✔\033[0m  %s\n' "$*"; }
die()  { printf '\033[1;31m[FATAL]\033[0m %s\n' "$*" >&2; exit 1; }

# ── locate project root ───────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

[[ -f VERSION ]] || die "VERSION file not found at project root."
VERSION="$(tr -d '[:space:]' < VERSION)"
[[ -n "$VERSION" ]] || die "VERSION file is empty."

RELEASE_DIR="release/v${VERSION}"
TARBALL="${RELEASE_DIR}/kong-deploy-v${VERSION}.tar.gz"
SHA_FILE="${RELEASE_DIR}/kong-deploy-v${VERSION}.sha256.txt"

mkdir -p "$RELEASE_DIR"
log "Building release tarball for v${VERSION} ..."

# ── build kong-usermgmt image and export to staging dir ──────────────────────

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

log "Building kong-usermgmt:latest image ..."
# Use docker build directly — docker compose build would require all env vars
# (including KONG_PG_PASSWORD) to be set even though they are only needed at runtime.
docker build -t kong-usermgmt:latest ./usermgmt
ok "kong-usermgmt image built."

log "Saving kong-usermgmt:latest to images/kong-usermgmt.tar ..."
mkdir -p "$STAGE_DIR/images"
docker save kong-usermgmt:latest -o "$STAGE_DIR/images/kong-usermgmt.tar"
ok "Image saved ($(du -sh "$STAGE_DIR/images/kong-usermgmt.tar" | cut -f1))."

# ── build file list from git-tracked files ────────────────────────────────────
# Excludes: release/, *.tar.gz, *.tar, offline-package/, docs/superpowers/

INCLUDE_LIST="$(mktemp)"
trap 'rm -rf "$STAGE_DIR"; rm -f "$INCLUDE_LIST"' EXIT

git ls-files | grep -v \
  -e '^release/' \
  -e '^offline-package/' \
  -e '^docs/superpowers/' \
  -e '\.tar\.gz$' \
  -e '\.tar$' \
  > "$INCLUDE_LIST"

# Always include generated artifacts that may not be git-tracked yet
for extra in deploy.sh upgrade.sh .env.example nginx/.htpasswd.example scripts/build-release.sh docs/DEPLOY.md; do
  if [[ -f "$extra" ]] && ! grep -qxF "$extra" "$INCLUDE_LIST"; then
    printf '%s\n' "$extra" >> "$INCLUDE_LIST"
  fi
done

# ── safety: confirm secrets are excluded ─────────────────────────────────────

if grep -qxF ".env" "$INCLUDE_LIST"; then
  die "SAFETY: .env is in the file list — aborting. Check your git ls-files output."
fi
if grep -qxF "nginx/.htpasswd" "$INCLUDE_LIST"; then
  die "SAFETY: nginx/.htpasswd is in the file list — aborting."
fi
if grep -E '^data/' "$INCLUDE_LIST"; then
  die "SAFETY: data/ entries found in file list — aborting."
fi

# ── stage all source files then add images/ ───────────────────────────────────
# Strategy: copy everything into a single tempdir, then tar czf once.
# Avoids the broken 'tar rzf' (cannot append to compressed archives).

SOURCE_STAGE="$STAGE_DIR/src"
mkdir -p "$SOURCE_STAGE"

# Copy git-tracked source files preserving directory structure
while IFS= read -r f; do
  dest="$SOURCE_STAGE/$f"
  mkdir -p "$(dirname "$dest")"
  cp "$f" "$dest"
done < "$INCLUDE_LIST"

# ── safety check: VERSION must be in the staged files ───────────────────────

[[ -f "$SOURCE_STAGE/VERSION" ]] || die "SAFETY: VERSION not found in staged files — aborting."

# ── create tarball from single staged directory ───────────────────────────────
# images/ subdirectory (with kong-usermgmt.tar) is already inside $STAGE_DIR.
# We need both src/ contents and images/ in the archive under one prefix.

COMBINED="$STAGE_DIR/combined"
mkdir -p "$COMBINED"

# Move staged source into combined/
cp -a "$SOURCE_STAGE/." "$COMBINED/"

# Move images/ into combined/
cp -a "$STAGE_DIR/images" "$COMBINED/images"

tar czf "$TARBALL" \
  -C "$COMBINED" \
  --transform "s|^\./||" \
  --transform "s|^|kong-deploy-v${VERSION}/|" \
  .

ok "Tarball created."

# ── checksum ──────────────────────────────────────────────────────────────────

( cd "$(dirname "$TARBALL")" && sha256sum "$(basename "$TARBALL")" ) > "$SHA_FILE"
ok "sha256: $(cat "$SHA_FILE")"

# ── report ────────────────────────────────────────────────────────────────────

FILE_COUNT="$(tar tzf "$TARBALL" | wc -l)"
SIZE="$(du -sh "$TARBALL" | cut -f1)"

printf '\n'
printf '══════════════════════════════════════════════════════════\n'
printf '  Release: v%s\n' "$VERSION"
printf '  Tarball: %s\n' "$TARBALL"
printf '  Size:    %s   Files: %s\n' "$SIZE" "$FILE_COUNT"
printf '  SHA256:  %s\n' "$SHA_FILE"
printf '\n'
printf '  Verifying secrets excluded:\n'

# Note: `{ tar tzf ... || true; }` prevents SIGPIPE from failing the pipeline
# under set -euo pipefail when grep -q exits early after finding a match.

if { tar tzf "$TARBALL" || true; } | grep -q '\.env$'; then
  printf '  [FAIL] .env found in tarball!\n'
else
  printf '  [OK] .env not in tarball\n'
fi

# Bug 8 fix: use two separate commands so grep -v does not suppress the pipeline exit code
if { tar tzf "$TARBALL" || true; } | grep -E '\.htpasswd$' | grep -qv '\.htpasswd\.example'; then
  die "SAFETY: real .htpasswd found in tarball — aborting."
fi
printf '  [OK] real .htpasswd not in tarball\n'

if { tar tzf "$TARBALL" || true; } | grep -qE '^kong-deploy-v[^/]+/data/'; then
  printf '  [FAIL] data/ entries found in tarball!\n'
else
  printf '  [OK] data/ not in tarball\n'
fi

if { tar tzf "$TARBALL" || true; } | grep -q "kong-deploy-v${VERSION}/images/kong-usermgmt.tar"; then
  printf '  [OK] images/kong-usermgmt.tar present in tarball\n'
else
  printf '  [FAIL] images/kong-usermgmt.tar NOT found in tarball!\n'
fi

if { tar tzf "$TARBALL" || true; } | grep -q "kong-deploy-v${VERSION}/VERSION"; then
  printf '  [OK] VERSION present in tarball\n'
else
  die "SAFETY: VERSION not found in tarball — aborting."
fi

printf '══════════════════════════════════════════════════════════\n\n'

# ── stage loose files next to the tarball for direct PCA transfer ────────────
# Operator copies the whole release/vX.Y.Z/ directory to USB → PCA.
# These files sit OUTSIDE the tarball so the operator can run pca-upgrade.sh
# without extracting first.

log "Staging loose files in $RELEASE_DIR/ for direct copy to PCA ..."

cp -f pca-deploy.sh          "$RELEASE_DIR/pca-deploy.sh"
chmod +x                       "$RELEASE_DIR/pca-deploy.sh"
cp -f PCA-UPGRADE-GUIDE.md   "$RELEASE_DIR/PCA-UPGRADE-GUIDE.md"
ok "pca-deploy.sh + PCA-UPGRADE-GUIDE.md copied alongside tarball"

# ── include base Docker images if available on the host ──────────────────────
# These are used by Kong's compose stack. PCA loaded them during the original
# kong-offline-package install; including them here lets a fresh PCA box come
# up without needing the old offline-package separately.

BASE_IMAGES_DIR="$RELEASE_DIR/images"
mkdir -p "$BASE_IMAGES_DIR"

for src in kong-oss-3.9.tar postgres-15-alpine.tar nginx-alpine.tar; do
  if [[ -f "$src" ]]; then
    cp -f "$src" "$BASE_IMAGES_DIR/$src"
    ok "Included $src ($(du -sh "$BASE_IMAGES_DIR/$src" | cut -f1))"
  else
    printf '  [WARN] base image %s not found at project root — skipping (PCA must already have it loaded)\n' "$src"
  fi
done

# ── README for the operator ──────────────────────────────────────────────────

cat > "$RELEASE_DIR/README.txt" <<EOF
SEHC AI Gateway — Release v${VERSION}
=========================================

This directory is self-contained. Copy the WHOLE folder to USB / file share,
then to PCA. The operator does not need to download anything else.

Files in this directory:

  kong-deploy-v${VERSION}.tar.gz       Code + kong-usermgmt image
  kong-deploy-v${VERSION}.sha256.txt   Checksum
  pca-deploy.sh                         One-shot deploy script — RUN THIS
  PCA-UPGRADE-GUIDE.md                  Operator guide
  images/                               Base Docker images
    kong-oss-3.9.tar
    postgres-15-alpine.tar
    nginx-alpine.tar
  README.txt                            This file

On PCA, from this directory, ONE command does everything:

  sudo ./pca-deploy.sh kong-deploy-v${VERSION}.tar.gz

The script auto-detects:
 * FRESH INSTALL  — no Kong running. Creates /opt/kong, generates secrets,
                    sets a random admin password, brings the full stack up.
 * UPGRADE        — Kong already running. Backs up, extracts new code,
                    restarts only the services that changed.

For rollback:    sudo ./pca-deploy.sh --rollback
For custom dir:  sudo ./pca-deploy.sh kong-deploy-v${VERSION}.tar.gz --install-dir /opt/kong
EOF
ok "README.txt written"

# ── final size report ────────────────────────────────────────────────────────

TOTAL_SIZE="$(du -sh "$RELEASE_DIR" | cut -f1)"
printf '\n══════════════════════════════════════════════════════════\n'
printf '  Release directory: %s\n' "$RELEASE_DIR"
printf '  Total size:        %s (everything PCA needs)\n' "$TOTAL_SIZE"
printf '  Copy this whole directory to USB → PCA, then:\n'
printf '    sudo ./pca-deploy.sh kong-deploy-v%s.tar.gz\n' "$VERSION"
printf '══════════════════════════════════════════════════════════\n\n'
