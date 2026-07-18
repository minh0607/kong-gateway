# Client Integration

> How applications connect **through** the gateway, and how to trust the self-signed
> certificate when HTTPS is required. The default guidance is: use plain HTTP `:8000`
> for internal server-to-server calls, HTTPS `:8443` only when required.

---

## 1. Connection decision rule

| Caller | Use | URL |
|---|---|---|
| Internal server-to-server (Dify, n8n, backends, Dockerized) | **HTTP `:8000`** | `http://<gateway>:8000/<route>/v1` |
| When HTTPS is required | **HTTPS `:8443`** | `https://<gateway>:8443/<route>/v1` (trust the cert) |

The OpenAI-compatible endpoints under a route are `/<route>/v1/chat/completions`
and `/<route>/v1/models`.

## 2. Sending the API key

The header depends on how the consumer's `key-auth` was configured:

| Style | Header sent by client | Stored credential |
|---|---|---|
| n8n | `x-api-key: <secret>` | `<secret>` |
| Dify / Bearer | `Authorization: Bearer <secret>` | `Bearer <secret>` (whole value) |

For Bearer-style consumers, when an app asks for just an "API key", give it the
**secret without** the `Bearer ` prefix; the app adds `Authorization: Bearer` itself.

## 3. Example — n8n → Kong → Ollama

- Kong service `ollaman8n` → `http://<Ollama-IP>:11433`
- Kong route `ollaman8n-route` → path `/ollaman8n`, `strip_path=true`
- `key-auth` `key_names = [apikey, X-API-Key, Authorization]`
- Consumer `n8n`, key stored as `Bearer <secret>`
- In n8n's Ollama credential:
  - Base URL: `http://<gateway>:8000/ollaman8n`
  - API Key: `<secret-without-Bearer-prefix>`

## 4. Trusting the self-signed cert (HTTPS `:8443`)

The proxy cert is self-signed with `SAN = IP:<box-ip>`. OS trust
(`update-ca-certificates`) covers curl / Go / browsers but **not** Python, Node,
Java, and does **not** reach inside Docker containers. Apply trust per runtime:

| Runtime | How |
|---|---|
| curl / Go / browser | Import cert into OS store (`update-ca-certificates`), or `curl -k` for a quick test. |
| Node | `NODE_EXTRA_CA_CERTS=/path/kong-proxy.crt` (clean append). |
| Java | `keytool -importcert` into the keystore. |
| Python (`requests`) | `REQUESTS_CA_BUNDLE` / `SSL_CERT_FILE` **replace** the bundle — build a **combined** bundle = `certifi.where()` contents **+** the Kong cert. Verify `grep -c 'BEGIN CERTIFICATE'` ≥ 100 or you drop public CAs. |

> Where to get the production cert: generated on the PCA at deploy — copy
> `/opt/kong/ssl/kong-proxy.crt` from the PCA to hand to clients. The DEV cert
> (`192.168.1.121`) is DEV-only; never distribute it to production clients.

## 5. Dify specifics

- Dify 1.x makes model HTTPS calls from the **`plugin_daemon`** container (not
  `api`/`worker`). Cert trust must be applied to **`api` + `worker` + `plugin_daemon`**
  or credential validation fails with `SSLError`.
- Wire cert trust via a `docker-compose.override.yaml` (never edit the original
  compose) so reverting = deleting the override.
- Helper scripts live in the repo `client/` directory
  (`trust-kong-cert.sh` / `.ps1`, `add-kong-cert-to-dify.sh`).

## 6. Common failure signatures

| Symptom | Likely cause |
|---|---|
| `401 Unauthorized` | Missing/wrong API key, or wrong header name for that consumer. |
| `403 Forbidden` | Key valid but consumer not in the service's ACL group (or IP blocked). |
| `404 no Route matched` | Wrong path prefix / route not created. |
| `SSLError` / cert errors | HTTPS without trusting the self-signed cert (or missing on `plugin_daemon`). |
| Stream cut mid-response | Client-side timeout below the model's response time (raise it; Kong is already 600s). |
