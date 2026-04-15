#!/bin/bash
set -e

echo "============================================"
echo "  Kong API Gateway - Offline Installation"
echo "============================================"
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGES_DIR="$SCRIPT_DIR/images"

# Check Docker
if ! command -v docker &> /dev/null; then
    echo "[ERROR] Docker is not installed."
    exit 1
fi

if ! docker compose version &> /dev/null; then
    echo "[ERROR] Docker Compose plugin is not available."
    exit 1
fi

echo "[1/5] Loading Docker images..."
echo "  - PostgreSQL 15..."
docker load -i "$IMAGES_DIR/postgres-15-alpine.tar"
echo "  - Kong Gateway 3.9..."
docker load -i "$IMAGES_DIR/kong-oss-3.9.tar"
echo "  - Nginx (auth proxy)..."
docker load -i "$IMAGES_DIR/nginx-alpine.tar"
echo "  - User Management + Session Auth..."
docker load -i "$IMAGES_DIR/kong-usermgmt.tar"
echo ""

echo "[2/5] Detecting server IP..."
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "  Detected: $SERVER_IP"
read -p "  Use this IP? (y/N or enter custom IP): " IP_INPUT
if [ "$IP_INPUT" != "y" ] && [ "$IP_INPUT" != "Y" ] && [ -n "$IP_INPUT" ]; then
    SERVER_IP="$IP_INPUT"
fi
echo "  Using: $SERVER_IP"

# Update compose and nginx config with correct IP
sed -i "s/192.168.1.121/$SERVER_IP/g" "$SCRIPT_DIR/docker-compose.yml"
sed -i "s/192.168.1.121/$SERVER_IP/g" "$SCRIPT_DIR/nginx/default.conf"
echo ""

echo "[3/5] Setting default admin password..."
# Create htpasswd with default password if not exists or reset
if command -v htpasswd &> /dev/null; then
    htpasswd -bc "$SCRIPT_DIR/nginx/.htpasswd" kong 'kong@2026'
else
    # Use the bundled one from the usermgmt image
    docker run --rm -v "$SCRIPT_DIR/nginx:/data" kong-usermgmt:latest \
        htpasswd -bc /data/.htpasswd kong 'kong@2026'
fi

# Set default admin role
echo '{"kong": "admin"}' > "$SCRIPT_DIR/nginx/roles.json" 2>/dev/null || true
echo ""

echo "[4/5] Starting all services..."
cd "$SCRIPT_DIR"
docker compose up -d
echo ""

echo "[5/5] Waiting for Kong to be ready..."
MAX_WAIT=120
ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT ]; do
    if docker inspect kong --format='{{.State.Health.Status}}' 2>/dev/null | grep -q healthy; then
        echo ""
        echo "============================================"
        echo "  Kong is UP and RUNNING!"
        echo "============================================"
        echo ""
        echo "  Kong Proxy:        http://$SERVER_IP:8000"
        echo "  Kong Admin API:    http://$SERVER_IP:8001"
        echo "  Kong Manager GUI:  http://$SERVER_IP:8002"
        echo "  User Management:   http://$SERVER_IP:8002/users/ (admin only)"
        echo ""
        echo "  Login:  kong / kong@2026  (role: admin)"
        echo ""
        echo "  Roles:"
        echo "    admin  - Kong Manager + User Management"
        echo "    user   - Kong Manager only"
        echo ""
        echo "  Configure LLM route:"
        echo "    bash $SCRIPT_DIR/setup-llm-route.sh <LLM_HOST> <LLM_PORT>"
        echo ""
        exit 0
    fi
    sleep 3
    ELAPSED=$((ELAPSED + 3))
    printf "."
done

echo ""
echo "[WARNING] Kong did not become healthy within ${MAX_WAIT}s."
echo "Check logs: docker compose -f $SCRIPT_DIR/docker-compose.yml logs"
exit 1
