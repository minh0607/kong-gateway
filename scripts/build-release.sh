#!/usr/bin/env bash
# SEHC AI Gateway — build a release tarball for distribution.
# Output: release/v<VERSION>/kong-deploy-v<VERSION>.tar.gz  + sha256.txt
# Safe to run on DEV — creates files only, never touches the running stack.
set -euo pipefail

# ── helpers ──────────────────────────────────────────────────────────────────

log()  { printf '\n\033[1;34m[build-release]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✔\033[0m  %s\n' "$*"; }
die()  { printf '\033[1;31m[FATAL]\033[0m %s\n' "$*" >&2; exit 1; }

WITH_IMAGES=false
for arg in "$@"; do
  case "$arg" in
    --with-images) WITH_IMAGES=true ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

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

# ── build file list from git-tracked files ────────────────────────────────────
# Excludes: release/, *.tar.gz, *.tar, offline-package/, docs/superpowers/

INCLUDE_LIST="$(mktemp)"
trap 'rm -f "$INCLUDE_LIST"' EXIT

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

# ── create tarball ────────────────────────────────────────────────────────────

tar czf "$TARBALL" \
  --files-from="$INCLUDE_LIST" \
  --transform "s|^|kong-deploy-v${VERSION}/|"

if [[ "$WITH_IMAGES" == true ]]; then
  if [[ -d offline-package/images ]] && ls offline-package/images/*.tar 2>/dev/null | grep -q .; then
    log "Appending offline Docker image tarballs (--with-images) ..."
    IMAGES_LIST="$(mktemp)"
    trap 'rm -f "$INCLUDE_LIST" "$IMAGES_LIST"' EXIT
    find offline-package/images -name '*.tar' > "$IMAGES_LIST"
    tar rzf "$TARBALL" \
      --files-from="$IMAGES_LIST" \
      --transform "s|^|kong-deploy-v${VERSION}/|"
    ok "Offline images appended."
  else
    printf '\033[1;33m  !\033[0m  --with-images: no *.tar files found in offline-package/images/ — skipping.\n'
  fi
fi

# ── checksum ──────────────────────────────────────────────────────────────────

sha256sum "$TARBALL" > "$SHA_FILE"
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

if tar tzf "$TARBALL" | grep -q '\.env$'; then
  printf '  [FAIL] .env found in tarball!\n'
else
  printf '  [OK] .env not in tarball\n'
fi

if tar tzf "$TARBALL" | grep -qE '\.htpasswd$' | grep -v '\.htpasswd\.example'; then
  printf '  [WARN] .htpasswd may be present — verify manually\n'
else
  printf '  [OK] real .htpasswd not in tarball\n'
fi

if tar tzf "$TARBALL" | grep -qE '^kong-deploy-v[^/]+/data/'; then
  printf '  [FAIL] data/ entries found in tarball!\n'
else
  printf '  [OK] data/ not in tarball\n'
fi

printf '══════════════════════════════════════════════════════════\n\n'
