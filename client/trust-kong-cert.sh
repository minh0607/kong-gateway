#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# trust-kong-cert.sh — trust the SEHC AI Gateway self-signed proxy cert on a
# Linux CLIENT, so HTTPS to the gateway (:8443) works without -k / "allow
# self-signed". Run on each client machine that calls the gateway over HTTPS.
#
#   1. Copy kong-proxy.crt from the gateway:  sudo cat /opt/kong/ssl/kong-proxy.crt
#      (or scp /opt/kong/ssl/kong-proxy.crt) next to this script.
#   2. sudo ./trust-kong-cert.sh [path/to/kong-proxy.crt]
#
# Supports Debian/Ubuntu and RHEL/Fedora/Rocky trust stores.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CERT="${1:-$(dirname "$0")/kong-proxy.crt}"

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0 $*" >&2; exit 1; }
[[ -f "$CERT" ]]  || { echo "Certificate not found: $CERT" >&2; exit 1; }
openssl x509 -in "$CERT" -noout >/dev/null 2>&1 \
  || { echo "Not a valid PEM certificate: $CERT" >&2; exit 1; }

if   command -v update-ca-certificates >/dev/null 2>&1; then   # Debian / Ubuntu
  install -m 644 "$CERT" /usr/local/share/ca-certificates/sehc-kong-proxy.crt
  update-ca-certificates
elif command -v update-ca-trust >/dev/null 2>&1; then          # RHEL / Fedora
  install -m 644 "$CERT" /etc/pki/ca-trust/source/anchors/sehc-kong-proxy.crt
  update-ca-trust extract
else
  echo "No supported trust-store tool (update-ca-certificates / update-ca-trust)." >&2
  exit 1
fi

echo "✔ Trusted SEHC AI Gateway cert:"
openssl x509 -in "$CERT" -noout -subject -ext subjectAltName | sed 's/^/   /'
echo "   Test:  curl https://<PCA_IP>:8443/   (no -k needed now)"
