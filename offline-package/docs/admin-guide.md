# Kong API Gateway - Admin Guide

## Architecture Overview

```
                    +-------------------+
                    |   Web Server(s)   |
                    +--------+----------+
                             |
                    Port 8000 (HTTP) / 8443 (HTTPS)
                             |
                    +--------v----------+
                    |   Kong Gateway    |
                    |   (Proxy)         |
                    +--------+----------+
                             |
                    +--------v----------+
                    |   LLM Server      |
                    +-------------------+

  Management:
    Port 8001  ->  Admin API (direct, no auth)
    Port 8002  ->  Kong Manager GUI (session auth + role-based)
    Port 8444  ->  Admin API HTTPS (direct, no auth)
    Port 8888  ->  User Management API (admin only)
```

## Container Overview

| Container | Image | Purpose |
|-----------|-------|---------|
| kong | kong:3.9 | API Gateway (proxy + admin) |
| kong-database | postgres:15-alpine | PostgreSQL for Kong config |
| kong-bootstrap | kong:3.9 | Run DB migrations (exit after) |
| kong-auth-proxy | nginx:alpine | Session auth proxy for Kong Manager |
| kong-usermgmt | kong-usermgmt:latest | User management + session auth API |

## Authentication & Authorization

### Session-Based Login
- Browser-based login page at `/auth/login`
- Session cookie expires after **30 minutes**
- Logout button injected into Kong Manager GUI (top-right)
- No more browser-cached Basic Auth popups

### Role-Based Access Control

| Role | Kong Manager | User Management | Admin API (8001) |
|------|:---:|:---:|:---:|
| **admin** | Yes | Yes | Yes (direct) |
| **user** | Yes | No (403) | Yes (direct) |

- First user is **auto-promoted to admin**
- Cannot delete or demote the last admin
- Roles managed via User Management UI (`/users/`)

### Multi-IP Access
- Kong Manager works from **any server IP** (192.168.x.x, 10.x.x.x, etc.)
- XHR interceptor auto-rewrites hardcoded API URLs to current origin
- CORS headers configured on Admin API proxy

## User Management

Access: `http://<server-ip>:8002/users/` (admin only)

### Features
- **Add User** — username, password, role (admin/user)
- **Delete User** — with last-admin protection
- **Change Password** — per user
- **Promote/Demote** — toggle between admin and user roles
- **Role badges** — visual indicator of admin vs user

## Adding LLM Route

```bash
bash setup-llm-route.sh <LLM_HOST> <LLM_PORT>
```

Or manually via Kong Manager:
1. Login at `http://<server-ip>:8002`
2. Go to Services > Add Service
3. Set Host, Port, Path
4. Go to Routes > Add Route
5. Bind route to the service

## Troubleshooting

### Cannot access port 8002
- Check: `docker compose ps` — all containers should be running
- Check firewall: `sudo ufw allow 8002` or `iptables -I INPUT -p tcp --dport 8002 -j ACCEPT`

### CORS errors in Kong Manager
- The XHR interceptor handles this automatically
- If still seeing errors, hard-refresh the page (Ctrl+Shift+R)

### "Access Denied" on User Management
- Only `admin` role users can access `/users/`
- Check your role: login response shows `"role": "admin"` or `"user"`

### Kong not starting
```bash
docker logs kong 2>&1 | tail -20
docker logs kong-database 2>&1 | tail -10
```

### Reset admin password
```bash
docker exec kong-usermgmt htpasswd -b /data/.htpasswd kong 'newpassword'
```
