# Reference

> Quick lookup: ports, endpoints, storage layout, and common operator commands.

---

## 1. Ports

| Port | Service | Notes |
|---|---|---|
| `8000` | Proxy (HTTP) | Client → model, plain HTTP |
| `8443` | Proxy (HTTPS) | Client → model, self-signed per-box cert |
| `8001` | Admin API (HTTP) | Full control — internal only |
| `8444` | Admin API (HTTPS) | Full control over TLS |
| `8100` | Status API | Read-only `/status` + `/metrics` (scrape this) |
| `8002` | Kong Manager GUI | Console, served under `/aigw` |
| `8888` | `kong-usermgmt` | User-management API (container port 5000) |

## 2. Admin API endpoints (used by the tools)

| Method + path | Purpose |
|---|---|
| `GET /services`, `/routes`, `/consumers`, `/plugins`, `/acls`, `/key-auths` | List collections |
| `POST /services` `--data name=… url=…` | Create service (with timeouts) |
| `POST /services/{s}/routes --data name=… paths[]=… strip_path=true` | Create route |
| `POST /consumers/ --data username=…` | Create consumer |
| `POST /consumers/{c}/key-auth --data key=…` | Issue API key |
| `POST /consumers/{c}/acls --data group=…` | Join ACL group |
| `POST /services/{s}/plugins --data name=key-auth\|acl\|ip-restriction\|rate-limiting …` | Enable plugin |
| `PATCH /services/{s}` `--data url=…` | Re-point backend |
| `PATCH /plugins/{id}` `--data …` | Edit / toggle a plugin |
| `DELETE /routes/{id\|name}`, `/plugins/{id}`, `/services/{name}`, `/consumers/{name}` | Delete |

## 3. Storage layout (`data/`, bind-mounted, git-ignored)

| File | Purpose |
|---|---|
| `users.json` | role, email, MFA flag per user |
| `smtp.json` | SMTP overlay (host/port/user/pass/from/tls) |
| `mfa_state.json` | active MFA challenges |
| `lockouts.json` | password + IP failure counters |
| `revoked_sessions.json` | logout-invalidated cookie signatures |
| `audit/audit-YYYY-MM-DD.jsonl` | Flask audit log |
| `audit/access-current.jsonl` | nginx `/api/` access log |

Kong's own config (services/routes/consumers/plugins) lives in the Postgres named
volume `pg_data`, **not** in `data/`.

## 4. Common commands (run on the gateway host)

```bash
# --- Admin console: login + cookie ---
curl -s -c /tmp/c -X POST http://localhost:8002/auth/login \
  -H 'Content-Type: application/json' -d '{"username":"kong","password":"..."}'

# --- Promote a user to admin ---
docker exec kong-usermgmt python3 -c "
import json, datetime
path = '/data/users.json'
now = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
db = {'version': 1, 'users': {}}
try: db = json.load(open(path))
except: pass
db['users'].setdefault('USERNAME', {'role':'user','email':None,'created_at':now,'updated_at':now})
db['users']['USERNAME']['role'] = 'admin'
json.dump(db, open(path,'w'), indent=2)"

# --- Reset a console password ---
docker exec kong-usermgmt htpasswd -b /data/.htpasswd USERNAME NEWPASSWORD

# --- Tail today's audit log ---
docker exec kong-usermgmt tail /data/audit/audit-$(date +%Y-%m-%d).jsonl

# --- Fix proxy cert permissions (old installs: "container kong is unhealthy") ---
sudo chmod 644 /opt/kong/ssl/kong-proxy.* && docker compose up -d

# --- Metrics for monitoring ---
curl -s http://<PCA_IP>:8100/metrics | head
```

## 5. Version & docs

- Current version: **1.0.3** (see `CHANGELOG.md`).
- Repo docs: `docs/DEPLOY.md`, `docs/MONITORING.md`, `PCA-UPGRADE-GUIDE.md`,
  `zabbix/README.md`, `monitoring-preview/VLLM-TOKENS.md`.
- Management tool: `kong-manage.sh` (see [Management Tool](04-management-tool.md)).

## 6. Glossary

| Term | Meaning |
|---|---|
| **Service** | An upstream target (a model server URL) registered in Kong. |
| **Route** | A path (e.g. `/coder`) that maps incoming requests to a service. |
| **Consumer** | An application identity that holds credentials. |
| **Credential** | A `key-auth` API key bound to a consumer (global to the consumer). |
| **ACL group** | A label on a consumer; the `acl` plugin allows specific groups per service. |
| **Plugin** | A Kong module attached to a service (key-auth, acl, ip-restriction, rate-limiting, prometheus, …). |
