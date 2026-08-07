# Model Portal — Web GUI

> A single-page admin web UI for the gateway, served at **`/kongportal`** behind
> the same admin login as the console. It manages the whole Kong object model
> (services, routes, consumers, plugins, upstreams) plus usage, request and audit
> views — the visual counterpart of `kong-manage.sh`. Styled to match the
> SEHC **IT Portal** design system.

---

## 1. Access

| How | URL |
|---|---|
| Direct (HTTPS) | `https://<box>:8452/kongportal` |
| Via IT Portal forward | `https://<box>/aigw/kongportal` |

- **Admin-only.** The portal sits behind the same `_auth_check_admin` gate as the
  console: anonymous users are redirected to `/auth/login`, non-admins get a 403.
  Its API calls reuse the authenticated `/api` Admin proxy — no new auth surface.
- Switch links connect the portal and **Kong Manager** both ways.
- All portal reads/writes go through the admin session; nothing is exposed
  unauthenticated.

## 2. The 3-axis convention

The portal is opinionated around a naming convention so the gateway stays legible:

| Axis | Object | Naming |
|---|---|---|
| **Model** = capability | Service + Route | `svc-<slug>`, path `/<slug>`, ACL group `acl-<slug>` |
| **Server** | Kong tags on the service | `box:<host>`, `cap:<slug>`, `model:<name>` |
| **Project** = client | Consumer | `prj-<name>` + its own token + optional IP allow-list |

A project (consumer) is granted access to a model by being added to that model's
**ACL group**. This is many-to-many: one model → many projects, one project →
many models. Routes belong to exactly one service (one-to-many).

> Legacy / non-convention objects are **not hidden** — the Models list shows every
> service with a `managed` / `legacy` badge, and the Consumers tab lists every
> consumer.

## 3. Tabs

| Tab | Purpose |
|---|---|
| **Overview** | Health strip (Kong version, DB, connections, upstream health, **stray global-auth warning**), counts, and a Model ↔ Project access matrix. |
| **Wizard** | Guided setup — create a model, its route and a project in one flow (see §4). |
| **Models** | Register a model (service + route + key-auth + acl + tags); edit backend / route; delete (cascades routes + plugins). "Show all" reveals legacy services. |
| **Routes** | List / add / edit / delete routes — many per service (paths, methods, hosts, strip_path). |
| **Projects** | Assign a project (consumer + token + ACL membership + optional IP restriction); edit its models / IPs / tags; delete. |
| **Consumers** | Add any consumer (incl. legacy), manage ACL group membership, and **issue / reveal / delete API keys**; edit username + tags. |
| **Upstreams** | Load-balancing pools — create an upstream, add backend targets (host:port + weight), watch target health. |
| **Usage** | Per-consumer traffic **broken down by model** (requests, 5xx, in/out bandwidth) from Prometheus metrics. CSV export. |
| **Requests** | Recent requests with **source IP** — who called which model from where (access log). CSV export. |
| **Test** | Send a real request through Kong with a project's key — see status / latency / body (key-auth, ACL and routing all apply). |
| **Audit** | Admin change log — who created / edited / deleted what, from which IP. |
| **Plugins** | Per-model protections: key-auth / acl / rate-limiting / request-size-limiting / bot-detection / cors toggles, plus a schema-driven form to add & edit **any** Kong plugin (no JSON). |
| **Backup** | Export the whole gateway config to JSON; restore it from a file (idempotent upsert by id, never deletes). |

Tables on Models / Routes / Consumers / Projects have a quick client-side filter.

## 4. Setup Wizard

A 4-step guided flow (**Model → Route → Project → Review**) with two modes in
step 1:

- **Create a new model** — provisions `svc-<slug>` (+ key-auth + `acl-<slug>`),
  its route, and a `prj-<name>` project (token + ACL membership + optional IP
  restriction). Guards against an already-existing slug so it never overwrites a
  model.
- **Use an existing model** — pick a model that already exists; the wizard skips
  service/route creation, auto-detects that model's ACL group, key header and
  route, and just adds a **new project** to it.

The review step summarises everything before it is created; the result links to
the **Test** tab.

## 5. Plugin config — schema-driven forms

Adding or editing a plugin renders a form generated from the plugin's real Kong
schema (`GET /schemas/plugins/<name>`): each config field becomes a typed input
(number / text / checkbox / select / comma-list), prefilled with defaults or the
current value. Filling the fields builds and submits the config automatically —
there is no raw-JSON step.

## 6. Health & safety warnings

The Overview health strip flags a **stray GLOBAL auth plugin** (`basic-auth`,
`key-auth`, `jwt`, `oauth2`, `hmac-auth`, `ldap-auth`, `mtls-auth`). Such a plugin
applies to **every** route and, combined with per-service key-auth, will **401
all API-key traffic**. Remove it in the Plugins tab unless it is intentional.

## 7. How auth actually resolves (for the Test tab)

A request through the proxy (`:8000` / `:8443`) is evaluated as:

| Case | Result |
|---|---|
| No API key | **401** — "No API key found in request" |
| Wrong key | **401** — "Unauthorized" |
| Valid key, ACL allows the model | passes → upstream (**200**, or 502 if the backend is unreachable) |
| Valid key, ACL does **not** allow the model | **403** — "You cannot consume this service" |

The Test tab reproduces exactly this by proxying through the real Kong pipeline
(admin-gated `/modeltest/` → `:8000`).

## 8. Backup / restore

- **Export** downloads a JSON snapshot of services, routes, plugins, consumers,
  ACLs, API keys, upstreams and targets. It contains **API keys in clear text** —
  store it securely.
- **Restore** upserts every entity by id (idempotent — updates existing,
  recreates missing) and never deletes. Use a backup taken from a healthy config.

## 9. Deployment

The portal ships inside the standard PCA bundle. `pca-deploy.sh` mounts
`portal/portal.html` into the auth-proxy, serves `/kongportal` behind the admin
gate over HTTPS (`:8452`), and enables the supporting plugins
(**Prometheus** for Usage, **file-log** for Requests, with logrotate). No schema
or data migration is involved — it is UI over the existing Admin API.

## 10. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Every request 401s despite valid keys | A stray **global auth plugin** (e.g. `basic-auth`) — the Overview health strip flags it; delete it in Plugins. |
| Model created but 401 on the header | Project created with the wrong key header. OpenAI-compatible clients send `Authorization: Bearer` — create the project with the *Authorization* header (Wizard / Projects), or set the model's key-auth `key_names` accordingly. |
| Test tab hangs / 502 | The model's backend is unreachable from Kong (expected on DEV where vLLM boxes aren't routable). |
| Pre-existing config "missing" | It is shown — tick **Show all** on Models, or look in the Consumers tab; nothing is deleted. |
| Real client IP shows the proxy | Behind an L4 proxy, set Kong `trusted_ips` + `real_ip_header=X-Forwarded-For`. |
