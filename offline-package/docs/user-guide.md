# Kong API Gateway - User Guide

## What is Kong?

Kong sits between your **Web Server** and your **LLM Server**. Instead of calling the LLM directly, your web server calls Kong, and Kong forwards the request.

```
Web Server  --->  Kong (:8000)  --->  LLM Server
```

Benefits:
- Centralized logging and monitoring
- Rate limiting to protect the LLM server
- Easy to switch LLM backends without changing web server code
- Access control and security plugins

---

## Web Interfaces

| URL | Purpose | Login Required |
|-----|---------|----------------|
| `http://<server-ip>:8002` | Kong Manager - view services, routes, plugins | Yes |
| `http://<server-ip>:8888` | User Management - add/remove user accounts | Yes |

Default login: `kong` / `kong@2026`

---

## Kong Manager GUI (Port 8002)

### Overview Page
Shows Kong Gateway status, number of services, routes, and plugins.

### Gateway Services
- View all backend services Kong proxies to
- Click a service to see its details and routes
- The LLM service shows your LLM server address and port

### Routes
- View all URL paths that Kong listens on
- Each route maps to a service
- Example: `/llm` route maps to `llm-service`

### Plugins
- View active plugins (rate limiting, logging, etc.)
- Plugins can be applied globally or per-service

---

## User Management GUI (Port 8888)

### Add User
1. Open `http://<server-ip>:8888`
2. Login with your credentials
3. Enter username (min 3 chars) and password (min 6 chars)
4. Click "Add User"
5. New user can immediately login to Kong Manager and User Management

### Change Password
1. Click "Change Password" next to the user
2. Enter new password
3. Click "Save"

### Delete User
1. Click "Delete" next to the user
2. Confirm deletion
3. Note: Cannot delete the last remaining user

---

## How to Call the LLM Through Kong

### Before (direct to LLM)
```bash
curl http://192.168.1.50:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "my-model",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

### After (through Kong)
```bash
curl http://<kong-ip>:8000/llm/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "my-model",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

The only change is the URL:
- **Before:** `http://LLM_IP:LLM_PORT/v1/...`
- **After:** `http://KONG_IP:8000/llm/v1/...`

Kong strips `/llm` from the path and forwards the rest.

---

## Common API Endpoints Through Kong

| Endpoint | Purpose |
|----------|---------|
| `GET /llm/v1/models` | List available models |
| `POST /llm/v1/chat/completions` | Chat completion |
| `POST /llm/v1/completions` | Text completion |
| `POST /llm/v1/embeddings` | Generate embeddings |

All prefixed with `/llm` when going through Kong.

---

## Integration Examples

### Python
```python
import requests

KONG_URL = "http://<kong-ip>:8000"

response = requests.post(f"{KONG_URL}/llm/v1/chat/completions", json={
    "model": "my-model",
    "messages": [
        {"role": "user", "content": "Hello, how are you?"}
    ]
})

print(response.json())
```

### JavaScript (Node.js)
```javascript
const response = await fetch("http://<kong-ip>:8000/llm/v1/chat/completions", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
        model: "my-model",
        messages: [
            { role: "user", content: "Hello, how are you?" }
        ]
    })
});

const data = await response.json();
console.log(data);
```

### cURL - Test Connection
```bash
# Check Kong is running
curl http://<kong-ip>:8000/

# List LLM models
curl http://<kong-ip>:8000/llm/v1/models

# Send a chat request
curl http://<kong-ip>:8000/llm/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"my-model","messages":[{"role":"user","content":"Hello"}]}'
```

---

## Troubleshooting for Users

| Problem | Solution |
|---------|----------|
| Can't login to Kong Manager | Check username/password, ask admin to reset via port 8888 |
| 502 Bad Gateway | LLM server is down or unreachable, contact admin |
| 404 Not Found | Check URL path starts with `/llm` |
| Connection timeout | LLM is overloaded or request too large, try again |
| 429 Too Many Requests | Rate limit reached, wait and retry |

For other issues, contact your system administrator or refer to the Troubleshooting Guide.
