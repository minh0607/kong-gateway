Kong API Gateway - Offline Package
===================================

Architecture:
  Web Server  --->  Kong (:8000)  --->  LLM Server

Ports:
  8000  - Kong Proxy HTTP
  8001  - Kong Admin API HTTP (direct, no auth)
  8002  - Kong Manager GUI (session auth + role-based access)
  8443  - Kong Proxy HTTPS
  8444  - Kong Admin API HTTPS (direct, no auth)
  8888  - User Management GUI (admin role only)

Default Login:
  Username: kong
  Password: kong@2026
  Role: admin (first user auto-promoted)

Roles:
  admin  - Kong Manager + User Management (create/delete users, change roles)
  user   - Kong Manager only

Security Features:
  - Session-based login (cookie expires after 30 minutes)
  - Logout button on Kong Manager (top-right corner)
  - Role-based access control (admin/user)
  - XHR rewrite for multi-IP access (works from any server IP)
  - CORS headers on Admin API proxy
  - Cannot delete or demote the last admin

Installation:
  1. Copy this entire folder to the PCA server
  2. Run: sudo bash install.sh
  3. Open Kong Manager: http://<server-ip>:8002
  4. Manage users: http://<server-ip>:8002/users/ (admin only)
  5. Configure LLM: bash setup-llm-route.sh <LLM_HOST> <LLM_PORT>

Files:
  images/kong-oss-3.9.tar         Kong Gateway
  images/postgres-15-alpine.tar   PostgreSQL database
  images/nginx-alpine.tar         Auth proxy for Kong Manager
  images/kong-usermgmt.tar        User Management + Session Auth
  docker-compose.yml              Full stack definition
  nginx/default.conf              Nginx proxy config (session auth + CORS + XHR rewrite)
  nginx/.htpasswd                 User credentials (htpasswd format)
  nginx/portal.html               Custom admin portal page
  docs/                           Admin guide, user guide, troubleshooting
