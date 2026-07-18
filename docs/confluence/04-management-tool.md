# Management Tool — `kong-manage.sh`

> An interactive, menu-driven admin tool over the Kong Admin API (`localhost:8001`).
> It centralizes the day-to-day operations: creating services/routes/consumers,
> applying the 3-layer security, and maintaining the gateway. Requires `python3`
> and `curl` on the host running it.

---

## 1. Running it

```bash
cd /opt/kong        # or /DATA/kong on DEV
./kong-manage.sh
```

The tool loops on a menu; after each task it returns to the menu (choose **18** to
exit). Destructive actions (delete) require typing the name again to confirm.

## 2. Menu — 17 operations

### Create / add
| # | Operation | What it does |
|---|---|---|
| 1 | **Create full stack** | Service + Route + Consumer + Key + ACL + key-auth + acl (+ optional IP restriction). One-shot new app. |
| 2 | **Add consumer** | New app (consumer + key) joined to an **existing** ACL group. |
| 8 | **Add route** | Add another path to an existing service. |
| 10 | **New service, existing ACL** | New backend (service + route) attached to an **existing** ACL group — existing keys work immediately, no new key issued. |

### View
| # | Operation | What it does |
|---|---|---|
| 3 | **Overview** | Full tree: every Service → backend → Route → Plugin, plus every Consumer → ACL group + key count. |
| 4 | **Quick list** | List all Services / Routes / Consumers, or the plugins of one service. |
| 16 | **Show consumer keys** | Reveal the actual API key value(s) of a consumer (sensitive). |

### Modify
| # | Operation | What it does |
|---|---|---|
| 6 | **Rotate / change API key** | Revoke all old keys of a consumer, issue a new one. |
| 7 | **Change backend URL** | Re-point a service to a different upstream (e.g. move to another vLLM box). |
| 9 | **Enable rate-limiting** | Add per-minute / per-hour limits to a service. |
| 13 | **Edit plugin (PATCH)** | Change an **existing** `rate-limiting` or `ip-restriction` in place (see idempotency note). |
| 15 | **Enable / disable plugin** | Toggle a plugin `enabled` without deleting it (debugging). |

### Delete
| # | Operation | What it does |
|---|---|---|
| 5 | **Delete** | Delete a Service (auto-removes its Routes + Plugins first) or a Consumer (cascades key + ACL). |
| 14 | **Delete single** | Remove one Route or one Plugin only. |

### Utilities / maintenance
| # | Operation | What it does |
|---|---|---|
| 11 | **Test route** | Health-check a route end-to-end through the proxy (`:8000`), classifying `200 / 401 / 403 / 404 / 000`. |
| 12 | **Backup** | Export the entire config to a timestamped JSON file. |
| 17 | **Restore** | Rebuild the config from a backup file (PUT-by-id upsert). |

## 3. Common workflows

**Onboard a new backend model (e.g. a coder model) that existing apps can use:**
1. `10` — new service `→ http://<box>:8000`, path `/coder`, attach existing ACL group.
2. `11` — test `/coder` with an existing key → expect `200`.

**Onboard a new application:**
1. `2` — create consumer + key in the target ACL group (pick header style).
2. `11` — test the target route with the new key.

**Change a rate limit that already exists:**
- Use `13` (PATCH the existing plugin) — **not** `9` again (that would try to add a
  second plugin of the same type and fail).

## 4. Idempotency note (important)

Kong allows only **one plugin of a given type per service**. Re-running an "enable"
action (e.g. `9` rate-limiting) on a service that already has that plugin **fails
with a duplicate error**. To change an existing plugin, use **`13` Edit plugin
(PATCH)**.

## 5. Requirements & portability

- Needs `python3` + `curl` on the machine running the script (it parses Admin API
  JSON with `python3`).
- Talks to `http://localhost:8001` — run it **on the gateway host**.
- The Admin API is unauthenticated and full-control; keep `:8001` internal only.
