# Backup & Restore

> Export the entire gateway configuration to a single JSON file and rebuild it from
> that file. Provided by `kong-manage.sh` (options **12** and **17**). Especially
> important in an air-gapped setup where losing the Postgres volume would otherwise
> mean re-creating every service, route, key, and ACL by hand.

---

## 1. What is backed up

Option **12 (Backup)** dumps these Kong collections into one timestamped file
`kong-backup-YYYYMMDD-HHMMSS.json`:

```json
{
  "exported_at": "20260718-135819",
  "services":  { "data": [ ... ] },
  "routes":    { "data": [ ... ] },
  "consumers": { "data": [ ... ] },
  "plugins":   { "data": [ ... ] },
  "acls":      { "data": [ ... ] },
  "key_auths": { "data": [ ... ] }
}
```

The file is validated as JSON before being written.

> ⚠️ **The backup contains real API keys** (`key_auths`). Treat it as a secret —
> store it securely and delete it when no longer needed.

## 2. How restore works

Option **17 (Restore)** reads a backup file and rebuilds the config using
**`PUT`-by-id (upsert)**, which preserves the original IDs, keys, ACL groups, and
foreign-key relationships. Entities are recreated in dependency order:

```
services → consumers → routes → key-auth / acl credentials → plugins
```

Restore is **idempotent**: running it against a Kong that already has some of the
entities simply re-writes them to the same IDs (no duplicates).

### Credential handling (why the body is trimmed)

For `key-auth` and `acl` credentials, restore sends **only the essential field**
(`{"key": ...}` or `{"group": ...}`); the ID is carried in the URL. Sending the full
stored object (with `consumer`, `ttl`, `created_at`) makes Kong return **HTTP 500**.
Services / routes / consumers / plugins are restored with their full bodies.

## 3. Procedure

**Backup (routine, before any risky change or upgrade):**
1. Run `kong-manage.sh` → **12**.
2. Note the printed path, e.g. `/opt/kong/kong-backup-20260718-135819.json`.
3. Copy it somewhere safe (and off-box if policy requires).

**Restore (disaster recovery / clone to another box):**
1. Ensure Kong is up (`curl -s http://localhost:8001/status`).
2. Run `kong-manage.sh` → **17**, give the backup file path, type `YES` to confirm.
3. Watch the per-entity `PUT ... -> 2xx` lines; the summary prints `N OK / M lỗi`.
4. Verify with **3 (Overview)**.

## 4. Verified behavior

A full round-trip was validated on the DEV gateway:

- Created a throwaway service + route + consumer + key + ACL + plugin.
- **Backup** captured them (including the key value).
- Deleted them (confirmed 404).
- **Restore** rebuilt all of them — **12 OK / 0 errors** — with the key and ACL
  group intact at their original IDs.

## 5. Scope & limitations

- Restore assumes the **same Kong major version** and schema.
- It covers services, routes, consumers, `key-auth`, `acl`, and plugins. Other
  credential types (if later added) would need to be included in the export.
- It does **not** manage the proxy TLS cert, `.env`, or user-management data
  (`data/*.json`) — those are handled by the deploy pipeline, not this tool.
