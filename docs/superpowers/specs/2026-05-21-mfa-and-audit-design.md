# SEHC AI Gateway — Email MFA, Per-User Action Logging, and Login Rebrand

**Status:** Design — awaiting user approval before implementation
**Date:** 2026-05-21
**Affects:** `/DATA/kong/usermgmt/`, `/DATA/kong/nginx/`, `/DATA/kong/docker-compose.yml`

---

## 1. Goals

1. **Email-based MFA.** Every user (including admins) must enter a 6-digit code emailed to them after a successful password step before the session cookie is issued.
2. **Per-user action logging.** Every authentication event, every user-management mutation, and every Kong Admin API call is written to a tamper-resistant JSONL audit trail. Admins can browse the trail in the GUI.
3. **Login-page rebrand.** Login page identifies the product as "SEHC AI GATEWAY".

This work also lands a small set of pre-feature refactors and security fixes called out by review (Section 13).

## 2. Out of scope

- TOTP / authenticator apps
- WebAuthn / hardware keys
- Backup codes / printed recovery codes
- Email notifications on admin actions
- Branding changes to Kong Manager GUI and user-management page (keep current strings)
- Migration of `.htpasswd` / `users.json` into Postgres

## 3. Architecture

```
                            ┌─────────────────────────────────────────┐
   browser ──────► nginx ───┤ /api/        →  kong:8001  (audit-logged)│
   (8002)         (auth_req)│ /auth/, /, /users/, /logs → kong-usermgmt│
                            └────────────────┬────────────────────────┘
                                             │
                          ┌──────────────────▼──────────────────┐
                          │ kong-usermgmt (Flask, blueprints)   │
                          │                                     │
                          │  app.py      — factory + startup    │
                          │  auth.py     — login + MFA + check  │
                          │  users.py    — user mgmt CRUD       │
                          │  audit.py    — writer + viewer      │
                          │  lockouts.py — counters             │
                          │  mailer.py   — SMTP client          │
                          └──────────────────┬──────────────────┘
                                             │
                            ┌────────────────▼──────────────────┐
                            │ /data volume (bind-mounted)       │
                            │   .htpasswd                       │
                            │   users.json                      │
                            │   mfa_state.json                  │
                            │   lockouts.json                   │
                            │   audit/                          │
                            │     audit-YYYY-MM-DD.jsonl  (Flask)│
                            │     access-YYYY-MM-DD.jsonl(nginx)│
                            └───────────────────────────────────┘
```

**Architecture choice — audit logging of `/api/`:** Kept the current nginx → Kong direct request path. nginx writes a JSON access log; Flask writes auth/user-mgmt events. The audit viewer merges both streams at read time. (Rejected: putting Flask in the `/api/` request path, which would add latency and a single point of failure on every Admin API call.)

## 4. Decisions register

| # | Decision | Choice |
|---|---|---|
| D1 | SMTP source | Internal relay (env-configured) |
| D2 | MFA scope | All users, every login |
| D3 | Email storage | JSON file (`users.json`) replacing `roles.json` |
| D4 | MFA code parameters | 6 digits, 5-minute TTL, 3 attempts |
| D5 | Email backfill for existing users | Admin populates all emails before flipping `MFA_ENFORCED` to true |
| D6 | Audit log storage | JSONL files |
| D7 | Audit log rotation | Daily, 90-day retention |
| D8 | Audit scope | Auth events + user mgmt + Kong Admin API (incl. GETs) |
| D9 | Account lockout | 5 failed passwords → 15-minute user lockout |
| D10 | IP lockout | 10 failed MFA codes from one IP → 15-minute IP lockout |
| D11 | Audit viewer | `/logs` page in admin GUI |
| D12 | `/api/` audit architecture | nginx access-logs `/api/`, Flask logs everything else, viewer merges |
| D13 | Branding scope | Login page only |
| D14 | Hot mutable state storage | JSON files + atomic writes + `flock` (Flask pinned to single worker) |
| D15 | IP binding for MFA challenge | Exact-IP match between step 1 and step 2 |
| D16 | nginx access log location | Shared file in `/data/audit/access-YYYY-MM-DD.jsonl` (volume mounted into both containers) |
| D17 | Username enumeration | Accept the residual leak — LAN-only deployment |

## 5. Data model

### 5.1 `users.json` (replaces `roles.json`)

```json
{
  "version": 1,
  "users": {
    "kong": {
      "role": "admin",
      "email": "admin@sehc.local",
      "created_at": "2026-05-21T08:00:00Z",
      "updated_at": "2026-05-21T08:00:00Z"
    }
  }
}
```

**Migration:** On Flask startup, if `roles.json` exists and `users.json` does not:

1. Read `roles.json`.
2. Build `users.json` with `email = null` for each user.
3. Write `users.json` via atomic write.
4. Rename `roles.json` to `roles.json.bak-<unix_ts>` (preserves rollback path).

Migration is idempotent — re-running it is a no-op if `users.json` already exists.

### 5.2 `mfa_state.json` — active MFA challenges

```json
{
  "<challenge_id>": {
    "username": "alice",
    "code_hmac": "hex...",
    "expires_at": 1716284400,
    "attempts_left": 3,
    "bound_ip": "192.168.1.50",
    "created_at": 1716284100,
    "resends_left": 1
  }
}
```

- `challenge_id` is `secrets.token_urlsafe(24)`.
- `code_hmac` is `hmac.new(SESSION_SECRET, code.encode(), sha256).hexdigest()`. **Not** plain `sha256(code+secret)`.
- Cleanup sweep (delete expired entries) runs at every write.

### 5.3 `lockouts.json` — counters and lockouts

```json
{
  "users": {
    "alice": { "failed": 3, "locked_until": null, "last_fail_at": 1716284100 }
  },
  "ips": {
    "192.168.1.50": { "mfa_failed": 7, "locked_until": null, "last_fail_at": 1716284100 }
  }
}
```

- Password lockout: 5 failed → `locked_until = now + 900s`. Counter clears on successful login or window expiry.
- MFA-IP lockout: 10 failed codes from one IP → `locked_until = now + 900s`. Independent of user lockout.
- Admin can clear lockouts via the user management GUI (audit event: `lockout.unlock`).

### 5.4 Atomic write contract

Every write to `users.json`, `mfa_state.json`, `lockouts.json` uses this pattern:

```
fd = open(<path>.tmp, "w")
flock(fd, LOCK_EX)
json.dump(...)
fd.flush(); os.fsync(fd); fd.close()
os.replace(<path>.tmp, <path>)
```

Read-modify-write cycles acquire an exclusive `flock` on a sibling `.lock` file for the duration. Flask is pinned to a single worker (`gunicorn --workers 1 --threads 4`) — locks serialize the threads.

## 6. Authentication flow

### 6.1 Step 1 — password verification

```
POST /auth/login
{ "username": "alice", "password": "..." }
```

Server actions:

1. Get source IP from `X-Real-IP` header (set by nginx from `$remote_addr`). **Never** from `X-Forwarded-For`.
2. If `lockouts.users[username].locked_until > now` → 423 (audit: `login.locked.user`).
3. If `lockouts.ips[ip].locked_until > now` → 423 (audit: `login.locked.ip`).
4. Verify password via `htpasswd -vb`. On fail: increment user counter, audit `login.password.fail`, return 401.
5. Look up `users.json[username]`. If no email: 409 (audit: `login.no_email`).
6. If `MFA_ENFORCED=false`:
   - Issue session cookie immediately with `mfa: false` claim.
   - Audit `login.bypass.mfa_disabled` (every such login is auditable).
   - Return `{ step: "ok", user, role }`.
7. If `MFA_ENFORCED=true`:
   - Generate code `f"{secrets.randbelow(1_000_000):06d}"`.
   - Compute `code_hmac`.
   - Write `mfa_state[challenge_id] = { username, code_hmac, expires_at = now+300, attempts_left=3, bound_ip=ip, resends_left=1 }`.
   - Send email (Section 6.4). On SMTP failure: delete the challenge, audit `login.mfa.send_fail`, return 503.
   - Audit `login.password.ok` + `login.mfa.sent`.
   - Return `{ step: "mfa_required", challenge_id, masked_email, expires_in: 300 }`.

`masked_email` masks the local part and the domain head: `a***@s***.local`.

### 6.2 Step 2 — code verification

```
POST /auth/mfa
{ "challenge_id": "...", "code": "123456" }
```

Server actions:

1. Get source IP from `X-Real-IP`.
2. If `lockouts.ips[ip].locked_until > now` → 423 (audit: `login.locked.ip`).
3. Lookup challenge by `challenge_id`. If missing or expired → 410 (audit: `login.mfa.expired`).
4. If `bound_ip != ip` (exact match) → delete challenge, audit `login.mfa.fail` with `details.reason="ip_mismatch"`, return 401.
5. Compute `hmac(code)` and constant-time compare with `code_hmac`. On mismatch:
   - `attempts_left -= 1`. If 0 → delete challenge.
   - Increment `lockouts.ips[ip].mfa_failed`.
   - Audit `login.mfa.fail` with `attempts_left`.
   - Return 401 with `attempts_left` (or 410 if challenge now dead).
6. On match:
   - Delete challenge.
   - Reset `lockouts.users[username].failed = 0`.
   - Issue session cookie with `mfa: true` claim.
   - Audit `login.mfa.ok` + `login.success`.
   - Return `{ message, user, role }`.

### 6.3 Resend

```
POST /auth/mfa/resend
{ "challenge_id": "..." }
```

- Cooldown: 60 seconds since last send for this challenge.
- `resends_left` starts at 1. If 0 → 429.
- Generates a **new** code and overwrites `code_hmac` and `expires_at`. The old code is invalidated.
- Audit `login.mfa.sent` with `details.resend=true`.

### 6.4 Email content (plain text only)

```
Subject: SEHC AI Gateway — your verification code

Hello {{username}},

Your one-time verification code is:

    {{code}}

It expires in 5 minutes. If you didn't try to sign in, ignore this email
and contact your administrator.

— SEHC AI Gateway
```

Sent via `email.message.EmailMessage` (handles header encoding; no manual string formatting of headers). Newlines in `username` are rejected at the user-creation endpoint (`Section 8`) so they cannot land in a Subject/Body.

### 6.5 Session cookie scheme

Existing cookie scheme is extended with a `mfa` claim:

```json
{ "u": "alice", "r": "user", "e": 1716286800, "mfa": true }
```

`auth_check` accepts the cookie if:
- HMAC matches
- `e > now`
- If `MFA_ENFORCED=true`, then `mfa == true`. (Backfill-phase cookies with `mfa: false` are rejected once enforcement flips on.)

Cookie flags: `HttpOnly`, `SameSite=Strict`, `Path=/`. `Secure=True` is set when the request arrived over HTTPS (`X-Forwarded-Proto: https`); otherwise omitted to keep HTTP development workable. Production deployment will run behind TLS; documented in the runbook.

`SESSION_SECRET` is required at startup. Flask refuses to start if the env var is missing **or** equals the legacy hardcoded default `"kong-session-secret-change-me-2026"`.

## 7. Audit log

### 7.1 Flask audit writer

Single helper `audit.write(event, actor, ip, target=None, details=None)`. All call sites go through this helper — no ad-hoc `open(..., "a")` writes.

```python
{"ts": "<utc iso8601 ms>", "actor": "alice", "actor_role": "user",
 "ip": "192.168.1.50", "event": "login.mfa.ok", "target": null,
 "details": {}}
```

- `actor` is the session user; `"anonymous"` when no session (e.g., failed pre-auth events).
- `actor_role` is resolved from `users.json` for known users, `null` otherwise.
- All values written via `json.dumps` (never f-strings). Strings are arbitrary user input; `json.dumps` escapes newlines and control chars.
- Writer wraps each line in a try/except. On `OSError` it logs to stderr and flips a process-level `audit_healthy = False` flag exposed via `GET /healthz`. The request itself is **not** failed (audit failure must not break login), but the operator sees the unhealthy state.

### 7.2 Flask audit file

- Path: `/data/audit/audit-YYYY-MM-DD.jsonl` (UTC date).
- Filename is recomputed per write — handles midnight rollover.
- Daily housekeeping thread (started at boot, runs every 6h): deletes any `audit-*.jsonl` older than 90 days. Uses file mtime; tolerates manual cleanup.

### 7.3 Flask event taxonomy

| Source | Events |
|---|---|
| Auth | `login.password.ok`, `login.password.fail`, `login.locked.user`, `login.locked.ip`, `login.no_email`, `login.mfa.sent`, `login.mfa.ok`, `login.mfa.fail`, `login.mfa.expired`, `login.mfa.send_fail`, `login.bypass.mfa_disabled`, `login.success`, `logout`, `session.expired` |
| User mgmt | `user.create`, `user.delete`, `user.password.change`, `user.role.change`, `user.email.change`, `lockout.unlock` |
| System | `startup`, `mfa.enforced.state` (emitted at boot with current flag value), `audit.view` (capped — see Section 7.6) |

### 7.4 nginx access log for `/api/`

The `kong-auth-proxy` (nginx) container writes a parallel JSONL file. The auth subrequest already returns `X-Auth-User` and `X-Auth-Role`. nginx captures them with `auth_request_set` and writes:

```nginx
log_format audit_json escape=json
  '{"ts":"$time_iso8601","actor":"$auth_user","actor_role":"$auth_role",'
  '"ip":"$remote_addr","event":"kong.api.request","target":null,'
  '"details":{"method":"$request_method","path":"$request_uri",'
  '"status":$status,"bytes":$body_bytes_sent,"ms":$request_time}}';

# inside the /api/ location:
auth_request_set $auth_user  $upstream_http_x_auth_user;
auth_request_set $auth_role  $upstream_http_x_auth_role;
access_log /var/log/audit/access-$(date +%Y-%m-%d).jsonl audit_json;
```

nginx's `access_log` directive does not interpolate dates in the filename, so the runtime path is fixed:

```nginx
access_log /var/log/audit/access-current.jsonl audit_json;
```

Rotation is performed by the Flask housekeeping thread, scheduled at UTC 00:05:

1. Atomically rename `access-current.jsonl` → `access-YYYY-MM-DD.jsonl` (yesterday's date).
2. Send `USR1` to the nginx process so it reopens log file descriptors and creates a fresh `access-current.jsonl`.
   - The signal is delivered via `docker kill -s USR1 kong-auth-proxy`. The Flask container is granted access to the host Docker socket via a read-only bind mount of `/var/run/docker.sock` for this single purpose. (Alternative: ship a small Python helper that talks to Docker's HTTP API to avoid mounting the socket. Decided in PR-2 implementation; the rotation contract above is the spec.)
3. The viewer reads both `access-current.jsonl` (today's events) and `access-YYYY-MM-DD.jsonl` (past dates) and merges with Flask's `audit-*.jsonl`.

Failed `/_auth_check` (no session): `$auth_user` is empty. nginx writes `"actor":""`. The audit viewer normalizes empty string → `"anonymous"`.

### 7.5 Shared volume

`docker-compose.yml` mounts a host directory at `/data` for Flask **and** at `/var/log/audit` for nginx, pointing at the same host path. Permissions: directory owned by `uid 100` (nginx alpine default) with group write for the Flask user; both processes can append. Host backup operates on a single directory.

### 7.6 Audit viewer

`GET /logs` (admin-only) serves `logs.html`. Backed by `GET /api/logs` (Flask):

```
GET /api/logs?date=2026-05-21&actor=alice&event=login.*&limit=200&offset=0
```

- Reads both `audit-DATE.jsonl` and `access-DATE.jsonl` for the date, merges by `ts`, applies filters.
- `event` supports `prefix.*` glob; `actor` is exact match; `limit ≤ 1000`.
- Returns `{rows: [...], total, has_more}`.
- Audit viewer emits `audit.view` **only on the first page of a search** (filter params logged). Subsequent paginations of the same search do not emit, capping log self-growth.

## 8. User management

Existing endpoints extended:

| Method | Path | Change |
|---|---|---|
| GET | `/api/users` | Now returns `email` per user |
| POST | `/api/users` | Body adds `email` (required when `MFA_ENFORCED=true`). Validates: no newlines, no control chars, contains `@`, length 5–254. |
| PUT | `/api/users/<username>/email` | **NEW.** Admin sets/updates a user's email. Audited: `user.email.change`. |
| PUT | `/api/users/<username>/password` | Existing. |
| PUT | `/api/users/<username>/role` | Existing. |
| DELETE | `/api/users/<username>` | Existing. |
| POST | `/api/users/<username>/unlock` | **NEW.** Admin clears `lockouts.users[username]`. Audited: `lockout.unlock`. |

## 9. nginx changes

`/DATA/kong/nginx/default.conf`:

- New `log_format audit_json` (Section 7.4).
- New `auth_request_set` lines on both `/api/` and `/users/` location blocks (the variables are scoped per-location).
- New `/logs/` location proxying to Flask, identical to `/users/`.
- CORS lockdown on `/api/`: replace `add_header 'Access-Control-Allow-Origin' $http_origin always` with a static `add_header 'Access-Control-Allow-Origin' 'http://192.168.1.121:8002' always` (or the configured deployment origin). Removes the wildcard-with-credentials hole.

## 10. Configuration (docker-compose.yml)

New environment block on `kong-usermgmt`:

```yaml
environment:
  HTPASSWD_FILE: /data/.htpasswd
  USERS_FILE: /data/users.json
  MFA_STATE_FILE: /data/mfa_state.json
  LOCKOUTS_FILE: /data/lockouts.json
  AUDIT_DIR: /data/audit
  SESSION_SECRET: ${SESSION_SECRET:?must be set}
  SESSION_MAX_AGE: "1800"

  SMTP_HOST: ${SMTP_HOST:?must be set}
  SMTP_PORT: "587"
  SMTP_USER: ${SMTP_USER:-}        # optional — internal relay may not require auth
  SMTP_PASS: ${SMTP_PASS:-}        # optional — internal relay may not require auth
  SMTP_FROM: "SEHC AI Gateway <no-reply@sehc.local>"
  SMTP_USE_TLS: "true"             # set "false" if the internal relay is plain SMTP
  SMTP_TIMEOUT_SEC: "10"

  MFA_ENFORCED: "false"
  MFA_CODE_TTL_SEC: "300"
  MFA_MAX_ATTEMPTS: "3"
  MFA_RESEND_COOLDOWN_SEC: "60"

  PWD_LOCKOUT_THRESHOLD: "5"
  PWD_LOCKOUT_WINDOW_SEC: "900"
  IP_MFA_LOCKOUT_THRESHOLD: "10"
  IP_MFA_LOCKOUT_WINDOW_SEC: "900"

  AUDIT_RETENTION_DAYS: "90"
  TZ: "UTC"

volumes:
  - ./data:/data
  - ./nginx/.htpasswd:/data/.htpasswd
```

`kong-auth-proxy` gets the shared audit volume:

```yaml
volumes:
  - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
  - ./nginx/.htpasswd:/etc/nginx/.htpasswd:ro
  - ./nginx/portal.html:/etc/nginx/portal.html:ro
  - ./data/audit:/var/log/audit
```

Secrets (`SMTP_PASS`, `SESSION_SECRET`) come from a `.env` file beside `docker-compose.yml`. `.env` is gitignored.

## 11. Dockerfile change

`/DATA/kong/usermgmt/Dockerfile`:

- Adds `tzdata` to the `apk add` line. Existing `apache2-utils` (for `htpasswd`) stays.
- Adds `gunicorn` to `pip install` (currently the app runs Flask's dev server).
- Entrypoint changes from `python app.py` to `gunicorn --workers 1 --threads 4 --bind 0.0.0.0:5000 app:app`. Single worker keeps file locks meaningful; threads are fine because every state-mutating path takes the `flock`.

## 12. Login page rebrand

`/DATA/kong/usermgmt/static/login.html`:

- `<title>` → `SEHC AI Gateway — Login`
- `<h1>` → `SEHC AI GATEWAY`
- Adds the step-2 form (`<div id="mfa-step" style="display:none">`): masked email line, 6-digit code input, resend link, "Back to login" link, 5-minute countdown.
- JS extended into a two-state machine: `state = "password" | "mfa"`. Calls `/auth/login` then `/auth/mfa`.

Other surfaces (`index.html`, the nginx-injected logout bar, Kong Manager GUI) keep current strings.

## 13. Pre-feature refactors (land first)

These small changes must land **before** the feature code, in this order:

1. **`read_json_file(path, default)` utility** in a new `storage.py` — collapses the four current open-parse-return helpers into one.
2. **Blueprint split**: `auth.py`, `users.py`, `audit.py`, `mailer.py`, `lockouts.py`, `storage.py`. `app.py` becomes the Flask factory, runs the `users.json` migration on startup, schedules the retention sweep, registers blueprints. No behaviour change in this step — pure extraction.
3. **`tzdata` + `gunicorn` in Dockerfile**.
4. **`/data` bind-mount in docker-compose for `kong-usermgmt`**, plus the shared `/data/audit` mount into `kong-auth-proxy`.
5. **`SESSION_SECRET` startup assertion** in the factory: refuse to start if missing or equal to the legacy default.

Each is reviewable on its own.

## 14. Test strategy

Minimum 80% coverage, `pytest`.

**Unit:**
- `users.json` migration: `roles.json` present → migrated, backup created, idempotent re-run.
- HMAC code hashing + constant-time compare.
- Atomic write under interrupt (write half a file, ensure `users.json` is still readable).
- Lockout state transitions (threshold, window, reset, admin unlock).
- Audit-line schema fuzz: usernames containing `\n`, `\r`, `"`, `\\` round-trip through `json.dumps` and back.
- Retention sweep deletes only files older than N days.

**Integration (Flask test client):**
- Full happy path: password → email sent (SMTP mocked) → code → cookie issued with `mfa:true`.
- Wrong password 5× → 423 lockout, audited.
- 3 wrong codes → challenge dead, must restart login.
- 10 wrong codes from one IP across different usernames → IP locked.
- IP mismatch between step 1 and step 2 → 401, challenge deleted.
- Resend within cooldown → 429. After cooldown → new code, old code invalid.
- `MFA_ENFORCED=false` path: cookie issued with `mfa:false`. After flag flip, that cookie is rejected by `/auth/check`.
- User with no email + `MFA_ENFORCED=true` → 409.
- `SESSION_SECRET` missing or default → app refuses to start.
- Admin-only routes refuse non-admin sessions.
- SMTP timeout → 503, no challenge persisted, audit row written.
- Audit writer disk-full simulation → request still succeeds, `/healthz` reports `audit_healthy=false`.

**E2E (Playwright, optional):**
- Login page renders "SEHC AI GATEWAY".
- Two-step UI flips correctly; resend visible; countdown ticks.
- Audit viewer renders rows from both files merged.

**Manual checklist (runbook, not CI):**
- One real email round-trip against the internal SMTP relay.
- Lockout state survives container restart (because file-backed).
- `nginx -s reopen` after daily rotation produces a fresh file.

## 15. Rollout

1. Land Section 13 refactors (PR 1). No user-visible change.
2. Land MFA, lockouts, audit writer, mailer (PR 2) with `MFA_ENFORCED=false`. New writes start, audit log fills up.
3. Land audit viewer + login rebrand (PR 3).
4. Admin populates emails for every user via the GUI.
5. Operator verifies `audit-*.jsonl` and `access-*.jsonl` are accumulating, runs the manual SMTP round-trip.
6. Set `MFA_ENFORCED=true`, restart `kong-usermgmt`. `mfa.enforced.state` audit row records the flip.
7. Existing non-MFA session cookies are rejected on next `auth_check`; users re-login through MFA.

## 16. Threat model & residual risks

**Mitigated:**

- MFA bypass via `MFA_ENFORCED` flag flip: cookies stamped with `mfa` claim; backfill sessions invalidated when flag turns on. Flag changes audited at boot.
- IP spoofing: only `$remote_addr` via `X-Real-IP` is trusted; `X-Forwarded-For` is ignored for security decisions.
- Brute force: 6-digit code, 3 attempts per challenge, 10 codes per IP per 15 minutes.
- Length extension on code hash: HMAC instead of `sha256(code+secret)`.
- Concurrent-write corruption: atomic temp-file rename + `flock`.
- Lockout loss on restart: state persisted to disk.
- SMTP header injection: `EmailMessage` library; newline rejected in usernames/emails.
- Log injection: `json.dumps` (Flask) and `escape=json` (nginx) on all user-controlled strings.
- CORS wildcard with credentials: locked to a static origin.
- Default `SESSION_SECRET`: startup refuses to boot.
- Audit write failures: surfaced via `/healthz`, never silent.

**Accepted residual risk:**

- **Username enumeration** via `masked_email` (D17). LAN-only deployment makes this low-impact.
- **Lockout DoS** of legitimate users (an attacker can lock a known username for 15 min by repeating bad passwords). Mitigated only by admin manual unlock. Cost of stronger mitigation (CAPTCHA, device fingerprint) judged not worth it for this scale.
- **Strict IP binding (D15)** may friction users behind unstable networks (DHCP renew between two steps). The MFA code window is short (5 min) so likely rare; users can simply re-login if rejected. If friction observed in production, can be relaxed to /24 in a follow-up.
- **Single Flask worker** caps concurrent admin actions. Acceptable for a management plane; documented as a constraint to revisit only if the GUI becomes a bottleneck.
- **Read-time merge in audit viewer** keeps memory cost proportional to one day of logs (~tens of MB worst case). Fine at current scale; revisit if Kong Admin call volume increases 100×.

## 17. Backup & restore

`/data/` is now load-bearing for auth, audit, and lockout state. Runbook (out of scope here, follow-up doc) must specify:

- Nightly `tar` of `/data/` excluding `*.tmp` lock and temp files. `access-current.jsonl` is included (snapshot is consistent enough — at most a few seconds of in-flight access events at the tar moment).
- Restore drill quarterly.

## 18. Files touched

| Action | Path |
|---|---|
| New | `usermgmt/storage.py` |
| New | `usermgmt/auth.py` |
| New | `usermgmt/users.py` |
| New | `usermgmt/audit.py` |
| New | `usermgmt/mailer.py` |
| New | `usermgmt/lockouts.py` |
| New | `usermgmt/static/logs.html` |
| Modified | `usermgmt/app.py` (factory only) |
| Modified | `usermgmt/Dockerfile` (`tzdata`, `gunicorn`) |
| Modified | `usermgmt/static/login.html` (rebrand + two-step) |
| Modified | `nginx/default.conf` (audit log, `auth_request_set`, CORS lock, `/logs/` location) |
| Modified | `docker-compose.yml` (volumes, env block) |
| New | `.env.example` (documents SMTP + SESSION_SECRET) |
| Migration | `roles.json` → `roles.json.bak-<ts>` on first boot |
