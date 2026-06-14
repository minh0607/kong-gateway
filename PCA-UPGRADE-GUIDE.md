# PCA Upgrade Guide — SEHC AI Gateway

**Audience:** PCA operator performing a routine production upgrade.
**Time required:** ~10 minutes.
**Downtime:** ~30 seconds (only during the container restart in Step 4).

---

## When to use this guide

You have a new release tarball from the DEV team (e.g. `kong-deploy-v1.0.1.tar.gz`)
and want to upgrade the production Kong stack on PCA without losing:

- Existing users in `nginx/.htpasswd`
- Kong's services, routes, plugins, consumers (in the Postgres volume)
- Audit logs and runtime state under `./data/`

This guide is for **air-gapped PCA** — no internet or git access required.

---

## Step 0 — What to bring to PCA

From the DEV box, copy **three files** to your transfer medium (USB / file share / jumpbox):

| File | Where to find it on DEV |
|---|---|
| `kong-deploy-v1.0.1.tar.gz` | `/DATA/kong/release/v1.0.1/` |
| `kong-deploy-v1.0.1.sha256.txt` | `/DATA/kong/release/v1.0.1/` |
| `pca-upgrade.sh` | `/DATA/kong/` |

Drop all three into the same directory on PCA (e.g. `~/transfer/`).

> **First-time upgrades only:** for the next release after this one, `pca-upgrade.sh`
> will already be on PCA inside `/opt/kong/`, so you only need to copy 2 files.

---

## Step 1 — Verify the files arrived intact

```bash
cd ~/transfer
sha256sum -c kong-deploy-v1.0.1.sha256.txt
```

**Expected output:**
```
kong-deploy-v1.0.1.tar.gz: OK
```

If it says `FAILED` — copy the files again. Do not proceed.

---

## Step 2 — Pre-flight check

Confirm the existing stack is healthy before you start:

```bash
docker ps --format '{{.Names}}: {{.Status}}' | grep -E 'kong|postgres'
```

**Expected:** 4 containers, all `Up` and (most) `(healthy)`:

```
kong-usermgmt:   Up (healthy)
kong-auth-proxy: Up
kong:            Up (healthy)
kong-database:   Up (healthy)
```

If any container is unhealthy or missing, fix that first — don't upgrade on top of a broken install.

---

## Step 3 — Run the upgrade

**One command. That's the whole upgrade:**

```bash
sudo ./pca-upgrade.sh kong-deploy-v1.0.1.tar.gz
```

The script will:

1. Re-verify the SHA256.
2. Find the install dir (`docker inspect kong`).
3. Snapshot config + Postgres volume to `<install>/backups/pre-upgrade-<UTC-timestamp>/`.
4. Extract the new bundle (preserves your `.env` and `nginx/.htpasswd`).
5. Create `.env` if missing, with `KONG_PG_PASSWORD=kong_pass` so Kong can still reach the existing database.
6. Run `upgrade.sh --tarball-only` to load the new image and restart services.
7. Health-check and print a summary.

Watch the output. You should see green checkmarks for each step. The final block prints:

```
══════════════════════════════════════════════════════════
  Upgrade complete
  Backup:    /opt/kong/backups/pre-upgrade-...
  Login:     http://<pca-ip>:8002/
  ...
══════════════════════════════════════════════════════════
```

---

## Step 4 — Verify

### 4a. Container health

```bash
docker compose ps
```

All four services must be `Up` and `(healthy)`.

### 4b. Login page is the rebranded one

```bash
curl -s http://localhost:8002/auth/login | grep 'SEHC AI GATEWAY'
```

Must print a line containing `SEHC AI GATEWAY`.

### 4c. Existing kong user can still log in

Open a browser to `http://<pca-ip>:8002/` and sign in with the kong password you've been using. You should land on the Kong Manager dashboard with the new "SEHC AI GATEWAY" logo at the top.

### 4d. Kong's existing config is intact

In the Kong Manager dashboard, click **Services**. The list should show whatever services and routes you had before the upgrade.

If all four checks pass — **upgrade complete**.

---

## Step 5 — Post-upgrade configuration (optional but recommended)

The new version adds features. Configure them via the admin GUI:

1. **Set the kong admin's email** (required for MFA later):
   - Navigate to `http://<pca-ip>:8002/users/`
   - Click the email cell on the `kong` row, set your real email.

2. **Configure SMTP** (required before enabling MFA):
   - On the same Users page, find the **SMTP Settings** card.
   - Enter the production SMTP relay (`host`, `port`, optional user/pass).
   - Click **Save**, then **Send test**. Confirm the test email arrives.

3. **Enable MFA per-user** (optional, after SMTP works):
   - On the user list, click the **MFA: off** button next to a user.
   - It toggles to **MFA: on**. Next login by that user requires the emailed code.

4. **Browse the audit log** (admin only):
   - `http://<pca-ip>:8002/logs/` — filter by user, event, date.

---

## Step 6 — Monitoring (Zabbix / Grafana)

`pca-deploy.sh` already exposes metrics on the **Status API (`:8100/metrics`)** and
enables the Prometheus plugin. To wire this into Zabbix + Grafana (and alerting),
follow **[docs/MONITORING.md](docs/MONITORING.md)**:

```bash
# verify metrics are live on PCA
curl -s http://localhost:8100/metrics | grep -c '^kong_'   # > 0
```

Then import `zabbix/template_kong_http.xml` and create the Kong host — see
[zabbix/README.md](zabbix/README.md) for template + alerting detail. Open
`tcp/8100` from the monitoring host to the PCA box.

---

## What's new in v1.0.3 (verify after upgrade)

| Change | Check |
|---|---|
| **Proxy HTTPS** on `:8443` (self-signed IP cert) | `curl -k https://<pca-ip>:8443/` responds; cert auto-generated by `pca-deploy.sh` (use `--cert-ip <PCA_IP>` if auto-detect is wrong) |
| **Metrics** on `:8100` | `curl -s http://localhost:8100/metrics \| grep -c '^kong_'` > 0 |
| **Admin-only RBAC** | a `user`-role account now gets **403** on Kong Manager / `/api/` — only `admin` can use the console. Check your PCA user roles before upgrading so you don't lock out a non-admin who needs access. |

---

## Troubleshooting

### `KONG_PG_PASSWORD is required`

Step 3 did not run, or `.env` is missing the line. Fix:

```bash
cd /opt/kong   # or wherever Kong is installed
grep -q '^KONG_PG_PASSWORD=' .env || echo 'KONG_PG_PASSWORD=kong_pass' | sudo tee -a .env
docker compose up -d
```

### `kong-database` is unhealthy after upgrade

The database password in `.env` doesn't match the existing volume. Check:

```bash
grep KONG_PG_PASSWORD /opt/kong/.env
# must be exactly: KONG_PG_PASSWORD=kong_pass
```

If you accidentally changed it, set it back to `kong_pass` and `docker compose up -d`.

### `cannot connect to Docker daemon`

You forgot `sudo`:

```bash
sudo ./pca-upgrade.sh kong-deploy-v1.0.1.tar.gz
```

### Health check fails / can't reach `http://localhost:8002/`

Check container logs:

```bash
docker compose logs --tail 50 kong-usermgmt
docker compose logs --tail 50 kong-auth-proxy
```

If something is clearly broken, **roll back** (next section).

---

## Rollback

If the upgrade fails or behaves wrong, restore the previous state:

```bash
cd ~/transfer
sudo ./pca-upgrade.sh --rollback
```

This restores from the most recent backup automatically:
- All config files (`docker-compose.yml`, `nginx/default.conf`, `nginx/.htpasswd`, etc.)
- `.env`
- The Postgres named volume (`kong_pg_data`)

You'll be prompted to confirm before anything is changed. After rollback:

```bash
docker compose ps                       # confirm all healthy
curl -s http://localhost:8002/auth/login | head -3   # confirm page loads
```

The backup directory stays on disk under `<install>/backups/pre-upgrade-*` — you can inspect it at any time.

---

## Summary card (print this and tape it to the wall)

```
1. cd ~/transfer
2. sha256sum -c kong-deploy-v1.0.1.sha256.txt    →  must say OK
3. docker ps                                      →  all 4 services healthy
4. sudo ./pca-upgrade.sh kong-deploy-v1.0.1.tar.gz
5. docker compose ps                              →  all 4 services healthy
6. curl http://localhost:8002/auth/login | grep SEHC AI GATEWAY
7. Browser login as kong / your-password         →  Kong Manager dashboard
8. Set kong's email, configure SMTP, enable MFA as desired.

Rollback (if anything broke):
   sudo ./pca-upgrade.sh --rollback
```

---

**Need help?** Paste the script output (especially any red ✘ lines) to the DEV team along with `docker compose logs` for the failing container.
