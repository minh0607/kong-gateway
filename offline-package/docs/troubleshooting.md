# Kong API Gateway - Troubleshooting Guide

## Quick Diagnostics

```bash
# Check all container status
docker compose ps

# Check Kong health
docker exec kong kong health

# Check database connection
docker exec kong kong migrations list

# View all logs
docker compose logs

# View specific service logs
docker compose logs kong
docker compose logs kong-database
docker compose logs kong-auth-proxy
docker compose logs kong-usermgmt
```

---

## Common Issues

### 1. Kong Manager shows "Gateway Services could not be retrieved"

**Cause:** `KONG_ADMIN_GUI_URL` or `KONG_ADMIN_GUI_API_URL` uses wrong IP.

**Fix:**
```bash
# Check current IP in docker-compose.yml
grep "192.168" docker-compose.yml

# Edit docker-compose.yml, replace IP with your server IP
sed -i 's/192.168.1.121/YOUR_SERVER_IP/g' docker-compose.yml

# Restart
docker compose up -d
```

---

### 2. Container won't start / keeps restarting

**Check logs:**
```bash
docker compose logs kong --tail 50
```

**Database not ready:**
```bash
# Check database health
docker exec kong-database pg_isready -U kong

# If database is corrupted, reset it (WARNING: loses all config)
docker compose down -v
docker compose up -d
```

**Port already in use:**
```bash
# Find what's using the port
ss -tlnp | grep 8000

# Kill the process or change ports in docker-compose.yml
```

---

### 3. Cannot login to Kong Manager (port 8002)

**Check nginx auth proxy:**
```bash
docker compose logs kong-auth-proxy
```

**Reset password:**
```bash
# Generate new password hash
docker exec kong-auth-proxy htpasswd -nb username newpassword

# Or use the User Management GUI at port 8888
```

**Check .htpasswd file:**
```bash
cat nginx/.htpasswd
```

---

### 4. Cannot login to User Management (port 8888)

**Check container:**
```bash
docker compose logs kong-usermgmt
```

**Restart:**
```bash
docker compose restart kong-usermgmt
```

---

### 5. Proxy returns 502 Bad Gateway

**Cause:** LLM server is unreachable from Kong.

**Check:**
```bash
# Test connectivity from Kong container to LLM server
docker exec kong curl -v http://LLM_HOST:LLM_PORT/

# Check service config
docker exec kong curl -s http://localhost:8001/services/llm-service | python3 -m json.tool

# Check route config
docker exec kong curl -s http://localhost:8001/routes/llm-route | python3 -m json.tool
```

**Fix:**
```bash
# Update service with correct LLM address
bash setup-llm-route.sh CORRECT_LLM_HOST CORRECT_LLM_PORT
```

---

### 6. Proxy returns 404 Not Found

**Cause:** No route matches the request path.

**Check:**
```bash
# List all routes
docker exec kong curl -s http://localhost:8001/routes | python3 -m json.tool

# Test with correct path (must start with /llm)
curl http://localhost:8000/llm/v1/models
```

---

### 7. Connection timeout to LLM

**Increase timeout (default 60s):**
```bash
docker exec kong curl -s -X PATCH http://localhost:8001/services/llm-service \
  -d "connect_timeout=120000" \
  -d "write_timeout=120000" \
  -d "read_timeout=120000"
```

---

### 8. Docker images not loading

**Check disk space:**
```bash
df -h
docker system df
```

**Reload images:**
```bash
docker load -i images/kong-oss-3.9.tar
docker load -i images/postgres-15-alpine.tar
docker load -i images/nginx-alpine.tar
docker load -i images/kong-usermgmt.tar
```

---

### 9. Database migration failed

```bash
# Check bootstrap logs
docker compose logs kong-bootstrap

# Re-run migrations manually
docker compose run --rm kong-bootstrap kong migrations bootstrap

# If upgrading, run
docker compose run --rm kong-bootstrap kong migrations up
docker compose run --rm kong-bootstrap kong migrations finish
```

---

### 10. High memory / CPU usage

```bash
# Check resource usage
docker stats --no-stream

# Reduce Kong workers in docker-compose.yml, add to kong environment:
#   KONG_NGINX_WORKER_PROCESSES: 2
docker compose up -d kong
```

---

## Reset Everything

```bash
# Stop all containers and delete data
docker compose down -v

# Re-run install
bash install.sh
```

## Collect Logs for Support

```bash
# Save all logs to file
docker compose logs --no-color > kong-debug-logs.txt 2>&1
docker compose ps >> kong-debug-logs.txt
docker exec kong kong config >> kong-debug-logs.txt 2>&1
```
