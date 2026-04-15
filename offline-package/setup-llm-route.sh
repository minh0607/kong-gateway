#!/bin/bash
set -e

KONG_ADMIN="http://localhost:8001"

if [ $# -lt 2 ]; then
    echo "Usage: $0 <LLM_HOST> <LLM_PORT> [PROTOCOL]"
    echo ""
    echo "Examples:"
    echo "  $0 192.168.1.100 8080          # HTTP backend"
    echo "  $0 192.168.1.100 443 https     # HTTPS backend"
    echo ""
    echo "After setup, your web server calls:"
    echo "  http://<kong-ip>:8000/llm/v1/chat/completions"
    echo "  which proxies to:"
    echo "  http://<LLM_HOST>:<LLM_PORT>/v1/chat/completions"
    exit 1
fi

LLM_HOST="$1"
LLM_PORT="$2"
PROTOCOL="${3:-http}"

# Admin API is not exposed externally, call via docker
echo "Configuring Kong to proxy to LLM at ${PROTOCOL}://${LLM_HOST}:${LLM_PORT}"
echo ""

echo "[1/2] Creating LLM service..."
docker exec kong curl -s -X PUT http://localhost:8001/services/llm-service \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"llm-service\",
    \"protocol\": \"${PROTOCOL}\",
    \"host\": \"${LLM_HOST}\",
    \"port\": ${LLM_PORT},
    \"path\": \"/\"
  }" | python3 -m json.tool 2>/dev/null || true
echo ""

echo "[2/2] Creating LLM route..."
docker exec kong curl -s -X PUT http://localhost:8001/services/llm-service/routes/llm-route \
  -H "Content-Type: application/json" \
  -d '{
    "name": "llm-route",
    "paths": ["/llm"],
    "protocols": ["http", "https"],
    "strip_path": true,
    "preserve_host": false
  }' | python3 -m json.tool 2>/dev/null || true
echo ""

echo "============================================"
echo "  LLM Route configured!"
echo "============================================"
echo ""
echo "  Web Server  -->  http://<kong-ip>:8000/llm/..."
echo "       Kong   -->  ${PROTOCOL}://${LLM_HOST}:${LLM_PORT}/..."
echo ""
echo "  Test: curl http://localhost:8000/llm/v1/models"
echo ""
