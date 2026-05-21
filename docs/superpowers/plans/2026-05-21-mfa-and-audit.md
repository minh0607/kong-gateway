# SEHC AI Gateway — MFA + Audit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add email-based MFA, per-user action logging with admin viewer, and login-page rebrand to "SEHC AI GATEWAY" on the existing Kong usermgmt service.

**Architecture:** Extend Flask `kong-usermgmt` from one file into a blueprint layout. Hot mutable state (`mfa_state.json`, `lockouts.json`) lives on a `/data` bind mount written atomically under `flock`. nginx writes a parallel JSON access log for `/api/` calls; Flask merges both streams in a `/logs` admin viewer. Login flow becomes two-step (password → 6-digit emailed code → cookie). Pin Flask to a single gunicorn worker so file locks remain meaningful.

**Tech Stack:** Python 3.12 (Alpine), Flask, gunicorn, stdlib `smtplib`+`email.message.EmailMessage`, `hmac`+`secrets`, `fcntl.flock`, pytest, nginx (alpine), Docker Compose.

**Spec:** `docs/superpowers/specs/2026-05-21-mfa-and-audit-design.md`

---

## File Map

| Path | Responsibility | Status |
|---|---|---|
| `usermgmt/app.py` | Flask factory: load config, register blueprints, run migration, start retention thread | modified (shrunk to factory) |
| `usermgmt/storage.py` | `read_json_file`, atomic `write_json_file`, `with_flock` context | new |
| `usermgmt/auth.py` | Session helpers, login/MFA/logout/check endpoints, `mfa` cookie claim | new (extracted + extended) |
| `usermgmt/users.py` | `users.json` migration + user CRUD + email/unlock endpoints | new (extracted + extended) |
| `usermgmt/lockouts.py` | Per-user password counters, per-IP MFA counters, 15-min windows | new |
| `usermgmt/mailer.py` | SMTP client using `EmailMessage`, timeout, optional auth | new |
| `usermgmt/audit.py` | `write()` helper, retention + nginx rotation thread, `/logs` page + `/api/logs` viewer | new |
| `usermgmt/static/login.html` | Rebrand + two-step UI | modified |
| `usermgmt/static/logs.html` | Audit viewer page | new |
| `usermgmt/Dockerfile` | Add `tzdata`, `gunicorn`; switch entrypoint | modified |
| `usermgmt/requirements.txt` | Pin Flask + gunicorn (replaces inline pip in Dockerfile) | new |
| `usermgmt/tests/` | pytest unit + integration suites | new |
| `nginx/default.conf` | `log_format audit_json`, `auth_request_set`, CORS lockdown, `/logs/` location | modified |
| `docker-compose.yml` | Bind-mount `/data`, share audit dir with nginx, new env vars, docker socket for rotation | modified |
| `.env.example` | Documented `SESSION_SECRET`, `SMTP_*` | new |
| `.gitignore` | Add `.env`, `data/`, `__pycache__/`, `.pytest_cache/` | modified |

---

## Execution Order

**PR 1 — Refactors (no behaviour change):** T1–T7
**PR 2 — Storage + audit foundations:** T8–T11
**PR 3 — MFA login flow:** T12–T16
**PR 4 — Audit viewer + nginx + rebrand:** T17–T21

Land one PR at a time. PR 1 must merge before PR 2 starts.

---

## Conventions

- Working directory: `/DATA/kong`
- All paths in this plan are relative to that.
- Tests live under `usermgmt/tests/`. The pytest command from the repo root is `docker compose run --rm kong-usermgmt pytest -q` after T1 lands; until then, run via the host: `cd /DATA/kong/usermgmt && python -m pytest -q` (requires local pytest + Flask).
- Every task ends with `git add <files> && git commit -m "..."`. Use `feat:`, `refactor:`, `test:`, `chore:` prefixes per `~/.claude/rules/common/git-workflow.md`.
- Do **not** bundle multiple tasks into one commit.

---

# PR 1 — Refactors (no behaviour change)

These changes land first. After PR 1, the app behaves exactly as it does today; the structure is just ready to absorb the feature work.

---

## Task 1: Test infrastructure

**Files:**
- Create: `usermgmt/requirements.txt`
- Create: `usermgmt/requirements-dev.txt`
- Create: `usermgmt/tests/__init__.py` (empty)
- Create: `usermgmt/tests/conftest.py`
- Create: `usermgmt/pytest.ini`
- Modify: `.gitignore`

- [ ] **Step 1: Create `usermgmt/requirements.txt`**

```
flask==3.0.3
gunicorn==22.0.0
```

- [ ] **Step 2: Create `usermgmt/requirements-dev.txt`**

```
-r requirements.txt
pytest==8.2.2
pytest-cov==5.0.0
```

- [ ] **Step 3: Create `usermgmt/pytest.ini`**

```ini
[pytest]
testpaths = tests
addopts = -q --strict-markers
markers =
    unit: fast in-process tests
    integration: tests that hit the Flask test client
filterwarnings =
    ignore::DeprecationWarning
```

- [ ] **Step 4: Create `usermgmt/tests/conftest.py`**

```python
import os
import tempfile
import pytest


@pytest.fixture
def tmp_data_dir(monkeypatch):
    """Isolated /data tree per test."""
    with tempfile.TemporaryDirectory() as d:
        monkeypatch.setenv("HTPASSWD_FILE", os.path.join(d, ".htpasswd"))
        monkeypatch.setenv("USERS_FILE", os.path.join(d, "users.json"))
        monkeypatch.setenv("MFA_STATE_FILE", os.path.join(d, "mfa_state.json"))
        monkeypatch.setenv("LOCKOUTS_FILE", os.path.join(d, "lockouts.json"))
        monkeypatch.setenv("AUDIT_DIR", os.path.join(d, "audit"))
        os.makedirs(os.path.join(d, "audit"), exist_ok=True)
        monkeypatch.setenv("SESSION_SECRET", "test-secret-not-the-default-value-xx")
        yield d


@pytest.fixture
def session_secret(monkeypatch):
    monkeypatch.setenv("SESSION_SECRET", "test-secret-not-the-default-value-xx")
    yield "test-secret-not-the-default-value-xx"
```

- [ ] **Step 5: Update `.gitignore`**

```
data/
.env
__pycache__/
*.pyc
.pytest_cache/
.coverage
htmlcov/
```

- [ ] **Step 6: Verify the test runner works**

Run from `/DATA/kong/usermgmt`:

```bash
pip install -r requirements-dev.txt
python -m pytest --collect-only
```

Expected: `0 tests collected` (no failures, no errors).

- [ ] **Step 7: Commit**

```bash
git add usermgmt/requirements.txt usermgmt/requirements-dev.txt \
        usermgmt/pytest.ini usermgmt/tests/__init__.py usermgmt/tests/conftest.py \
        .gitignore
git commit -m "chore: add pytest infrastructure for usermgmt"
```

---

## Task 2: Storage helpers (`storage.py`)

**Files:**
- Create: `usermgmt/storage.py`
- Create: `usermgmt/tests/test_storage.py`

- [ ] **Step 1: Write failing tests**

`usermgmt/tests/test_storage.py`:

```python
import json
import os
import threading

import pytest

from storage import read_json_file, write_json_file, with_flock


pytestmark = pytest.mark.unit


def test_read_returns_default_when_missing(tmp_data_dir):
    path = os.path.join(tmp_data_dir, "nope.json")
    assert read_json_file(path, default={"x": 1}) == {"x": 1}


def test_round_trip(tmp_data_dir):
    path = os.path.join(tmp_data_dir, "round.json")
    write_json_file(path, {"a": 1, "b": [2, 3]})
    assert read_json_file(path, default={}) == {"a": 1, "b": [2, 3]}


def test_atomic_write_leaves_no_partial_file_on_crash(tmp_data_dir, monkeypatch):
    path = os.path.join(tmp_data_dir, "atomic.json")
    write_json_file(path, {"good": True})
    # Force os.replace to fail; the temp file should be cleaned up,
    # and the original should be intact.
    import storage as s

    def boom(_src, _dst):
        raise OSError("simulated crash")

    monkeypatch.setattr(s.os, "replace", boom)
    with pytest.raises(OSError):
        write_json_file(path, {"bad": True})

    assert read_json_file(path, default=None) == {"good": True}
    # No stray tmp files left
    leftovers = [f for f in os.listdir(tmp_data_dir) if f.endswith(".tmp")]
    assert leftovers == []


def test_flock_serialises_threads(tmp_data_dir):
    path = os.path.join(tmp_data_dir, "lock.json")
    write_json_file(path, {"count": 0})
    lock_path = path + ".lock"

    def increment():
        with with_flock(lock_path):
            data = read_json_file(path, default={"count": 0})
            data["count"] += 1
            write_json_file(path, data)

    threads = [threading.Thread(target=increment) for _ in range(20)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert read_json_file(path, default={})["count"] == 20
```

- [ ] **Step 2: Run tests — they fail**

```bash
cd /DATA/kong/usermgmt && python -m pytest tests/test_storage.py -v
```

Expected: `ModuleNotFoundError: No module named 'storage'`.

- [ ] **Step 3: Implement `usermgmt/storage.py`**

```python
"""Atomic JSON storage with file locking.

Every write goes through `write_json_file`, which writes a temp file
then `os.replace`s it onto the final path. Read-modify-write cycles
use `with_flock` to serialise concurrent threads.
"""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
import tempfile
from typing import Any, Iterator


def read_json_file(path: str, default: Any) -> Any:
    if not os.path.exists(path):
        return default
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def write_json_file(path: str, data: Any) -> None:
    dir_ = os.path.dirname(path) or "."
    os.makedirs(dir_, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=dir_, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except Exception:
        # Best-effort cleanup; ignore secondary failures.
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


@contextlib.contextmanager
def with_flock(lock_path: str) -> Iterator[None]:
    """Acquire an exclusive advisory lock on a sibling .lock file."""
    os.makedirs(os.path.dirname(lock_path) or ".", exist_ok=True)
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
```

- [ ] **Step 4: Run tests — they pass**

```bash
python -m pytest tests/test_storage.py -v
```

Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
git add usermgmt/storage.py usermgmt/tests/test_storage.py
git commit -m "feat: add atomic JSON storage with flock"
```

---

## Task 3: SESSION_SECRET startup assertion + config module

**Files:**
- Create: `usermgmt/config.py`
- Create: `usermgmt/tests/test_config.py`

This task extracts environment-variable reading into one place. Used by every later module.

- [ ] **Step 1: Write failing tests**

`usermgmt/tests/test_config.py`:

```python
import pytest

from config import Config, LEGACY_DEFAULT_SECRET


pytestmark = pytest.mark.unit


def test_missing_secret_raises(monkeypatch):
    monkeypatch.delenv("SESSION_SECRET", raising=False)
    with pytest.raises(RuntimeError, match="SESSION_SECRET"):
        Config.from_env()


def test_legacy_default_secret_raises(monkeypatch):
    monkeypatch.setenv("SESSION_SECRET", LEGACY_DEFAULT_SECRET)
    with pytest.raises(RuntimeError, match="default"):
        Config.from_env()


def test_valid_config_loads(monkeypatch, tmp_data_dir):
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    cfg = Config.from_env()
    assert cfg.session_secret == "test-secret-not-the-default-value-xx"
    assert cfg.mfa_enforced is False  # default
    assert cfg.smtp_host == "mail.internal"
    assert cfg.smtp_port == 587
    assert cfg.audit_retention_days == 90


def test_mfa_enforced_true(monkeypatch, tmp_data_dir):
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    monkeypatch.setenv("MFA_ENFORCED", "true")
    cfg = Config.from_env()
    assert cfg.mfa_enforced is True
```

- [ ] **Step 2: Run tests — they fail**

```bash
python -m pytest tests/test_config.py -v
```

Expected: `ModuleNotFoundError: No module named 'config'`.

- [ ] **Step 3: Implement `usermgmt/config.py`**

```python
"""Centralised env-variable parsing. Read once at startup."""

from __future__ import annotations

import os
from dataclasses import dataclass

LEGACY_DEFAULT_SECRET = "kong-session-secret-change-me-2026"


def _bool(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Config:
    htpasswd_file: str
    users_file: str
    mfa_state_file: str
    lockouts_file: str
    audit_dir: str
    session_secret: str
    session_max_age: int
    smtp_host: str
    smtp_port: int
    smtp_user: str
    smtp_pass: str
    smtp_from: str
    smtp_use_tls: bool
    smtp_timeout_sec: int
    mfa_enforced: bool
    mfa_code_ttl_sec: int
    mfa_max_attempts: int
    mfa_resend_cooldown_sec: int
    pwd_lockout_threshold: int
    pwd_lockout_window_sec: int
    ip_mfa_lockout_threshold: int
    ip_mfa_lockout_window_sec: int
    audit_retention_days: int
    auth_proxy_container: str

    @classmethod
    def from_env(cls) -> "Config":
        secret = os.environ.get("SESSION_SECRET")
        if not secret:
            raise RuntimeError("SESSION_SECRET env var is required")
        if secret == LEGACY_DEFAULT_SECRET:
            raise RuntimeError(
                "SESSION_SECRET is set to the legacy default — refuse to start"
            )
        smtp_host = os.environ.get("SMTP_HOST", "")
        return cls(
            htpasswd_file=os.environ.get("HTPASSWD_FILE", "/data/.htpasswd"),
            users_file=os.environ.get("USERS_FILE", "/data/users.json"),
            mfa_state_file=os.environ.get("MFA_STATE_FILE", "/data/mfa_state.json"),
            lockouts_file=os.environ.get("LOCKOUTS_FILE", "/data/lockouts.json"),
            audit_dir=os.environ.get("AUDIT_DIR", "/data/audit"),
            session_secret=secret,
            session_max_age=int(os.environ.get("SESSION_MAX_AGE", "1800")),
            smtp_host=smtp_host,
            smtp_port=int(os.environ.get("SMTP_PORT", "587")),
            smtp_user=os.environ.get("SMTP_USER", ""),
            smtp_pass=os.environ.get("SMTP_PASS", ""),
            smtp_from=os.environ.get(
                "SMTP_FROM", "SEHC AI Gateway <no-reply@sehc.local>"
            ),
            smtp_use_tls=_bool(os.environ.get("SMTP_USE_TLS", "true")),
            smtp_timeout_sec=int(os.environ.get("SMTP_TIMEOUT_SEC", "10")),
            mfa_enforced=_bool(os.environ.get("MFA_ENFORCED", "false")),
            mfa_code_ttl_sec=int(os.environ.get("MFA_CODE_TTL_SEC", "300")),
            mfa_max_attempts=int(os.environ.get("MFA_MAX_ATTEMPTS", "3")),
            mfa_resend_cooldown_sec=int(
                os.environ.get("MFA_RESEND_COOLDOWN_SEC", "60")
            ),
            pwd_lockout_threshold=int(os.environ.get("PWD_LOCKOUT_THRESHOLD", "5")),
            pwd_lockout_window_sec=int(
                os.environ.get("PWD_LOCKOUT_WINDOW_SEC", "900")
            ),
            ip_mfa_lockout_threshold=int(
                os.environ.get("IP_MFA_LOCKOUT_THRESHOLD", "10")
            ),
            ip_mfa_lockout_window_sec=int(
                os.environ.get("IP_MFA_LOCKOUT_WINDOW_SEC", "900")
            ),
            audit_retention_days=int(os.environ.get("AUDIT_RETENTION_DAYS", "90")),
            auth_proxy_container=os.environ.get(
                "AUTH_PROXY_CONTAINER", "kong-auth-proxy"
            ),
        )
```

- [ ] **Step 4: Run tests — they pass**

```bash
python -m pytest tests/test_config.py -v
```

Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
git add usermgmt/config.py usermgmt/tests/test_config.py
git commit -m "feat: add Config with SESSION_SECRET fail-hard"
```

---

## Task 4: Dockerfile — tzdata + gunicorn

**Files:**
- Modify: `usermgmt/Dockerfile`

- [ ] **Step 1: Replace the Dockerfile**

`usermgmt/Dockerfile`:

```dockerfile
FROM python:3.12-alpine
RUN apk add --no-cache apache2-utils tzdata
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY *.py ./
COPY static/ static/
ENV TZ=UTC
EXPOSE 5000
CMD ["gunicorn", "--workers", "1", "--threads", "4", \
     "--bind", "0.0.0.0:5000", "--access-logfile", "-", "app:app"]
```

- [ ] **Step 2: Verify locally**

```bash
docker compose build kong-usermgmt
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add usermgmt/Dockerfile
git commit -m "chore: gunicorn entrypoint, add tzdata"
```

---

## Task 5: docker-compose — `/data` mount + shared audit dir + env block

**Files:**
- Modify: `docker-compose.yml`
- Create: `.env.example`

- [ ] **Step 1: Create `.env.example`**

```dotenv
# Required — Flask refuses to start if missing or equal to the legacy default.
SESSION_SECRET=change-me-to-a-random-32-char-string

# Internal SMTP relay
SMTP_HOST=mail.internal
SMTP_USER=
SMTP_PASS=
```

- [ ] **Step 2: Replace `kong-usermgmt` and `kong-auth-proxy` blocks in `docker-compose.yml`**

The full updated services block (everything else in `docker-compose.yml` is unchanged):

```yaml
  kong-auth-proxy:
    image: nginx:alpine
    container_name: kong-auth-proxy
    restart: unless-stopped
    depends_on:
      kong:
        condition: service_healthy
    volumes:
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
      - ./nginx/.htpasswd:/etc/nginx/.htpasswd:ro
      - ./nginx/portal.html:/etc/nginx/portal.html:ro
      - ./data/audit:/var/log/audit
    ports:
      - "8002:80"
    networks:
      - kong-net

  kong-usermgmt:
    image: kong-usermgmt:latest
    container_name: kong-usermgmt
    restart: unless-stopped
    volumes:
      - ./nginx/.htpasswd:/data/.htpasswd
      - ./data:/data
      - /var/run/docker.sock:/var/run/docker.sock:ro
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
      SMTP_USER: ${SMTP_USER:-}
      SMTP_PASS: ${SMTP_PASS:-}
      SMTP_FROM: "SEHC AI Gateway <no-reply@sehc.local>"
      SMTP_USE_TLS: "true"
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
      AUTH_PROXY_CONTAINER: "kong-auth-proxy"
      TZ: "UTC"
    ports:
      - "8888:5000"
    networks:
      - kong-net
```

The `:ro` mount of `/var/run/docker.sock` is read-only at the bind-mount level; Flask uses it only to send a `USR1` signal to nginx during daily rotation (Task 19).

- [ ] **Step 3: Create the `./data` directory**

```bash
mkdir -p /DATA/kong/data/audit
```

- [ ] **Step 4: Verify compose parses**

```bash
docker compose config --quiet
```

Expected: exits 0 with no output.

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml .env.example
git commit -m "chore: add /data bind mount, shared audit dir, MFA env vars"
```

---

## Task 6: Extract `users.py` (user CRUD, no new behaviour)

**Files:**
- Create: `usermgmt/users.py`
- Modify: `usermgmt/app.py` (remove the extracted code, register the blueprint)

The goal is to move existing endpoints (`list_users`, `add_user`, `delete_user`, `change_password`, `change_role`) into a blueprint **without changing any HTTP behaviour**. Email/unlock endpoints are added later (T12, T20).

- [ ] **Step 1: Create `usermgmt/users.py`**

```python
"""User management endpoints. Existing behaviour, blueprint form."""

from __future__ import annotations

import os
import subprocess

from flask import Blueprint, current_app, jsonify, request, send_from_directory

from storage import read_json_file, with_flock, write_json_file

bp = Blueprint("users", __name__)


def _htpasswd_path() -> str:
    return current_app.config["CONFIG"].htpasswd_file


def _users_path() -> str:
    return current_app.config["CONFIG"].users_file


def _lock_path(path: str) -> str:
    return path + ".lock"


def read_users() -> list[str]:
    users: list[str] = []
    path = _htpasswd_path()
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and ":" in line:
                    users.append(line.split(":")[0])
    return users


def read_entries() -> list[tuple[str, str]]:
    entries: list[tuple[str, str]] = []
    path = _htpasswd_path()
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and ":" in line:
                    u, h = line.split(":", 1)
                    entries.append((u, h))
    return entries


def save_entries(entries: list[tuple[str, str]]) -> None:
    path = _htpasswd_path()
    with with_flock(_lock_path(path)):
        with open(path, "w", encoding="utf-8") as f:
            for u, h in entries:
                f.write(f"{u}:{h}\n")


def apr1_hash(password: str) -> str:
    result = subprocess.run(
        ["htpasswd", "-nb", "tmp", password],
        capture_output=True, text=True, check=True,
    )
    return result.stdout.strip().split(":", 1)[1]


def verify_password(username: str, password: str) -> bool:
    result = subprocess.run(
        ["htpasswd", "-vb", _htpasswd_path(), username, password],
        capture_output=True,
    )
    return result.returncode == 0


# ─── users.json helpers ──────────────────────────────────────────

def _empty_db() -> dict:
    return {"version": 1, "users": {}}


def read_user_db() -> dict:
    return read_json_file(_users_path(), default=_empty_db())


def write_user_db(db: dict) -> None:
    with with_flock(_lock_path(_users_path())):
        write_json_file(_users_path(), db)


def get_role(username: str) -> str:
    db = read_user_db()
    rec = db.get("users", {}).get(username)
    return rec.get("role", "user") if rec else "user"


def set_role(username: str, role: str) -> None:
    db = read_user_db()
    rec = db["users"].setdefault(
        username, {"role": role, "email": None, "created_at": _now_iso(), "updated_at": _now_iso()}
    )
    rec["role"] = role
    rec["updated_at"] = _now_iso()
    write_user_db(db)


def remove_user_record(username: str) -> None:
    db = read_user_db()
    db.get("users", {}).pop(username, None)
    write_user_db(db)


def ensure_default_admin() -> None:
    db = read_user_db()
    if any(r.get("role") == "admin" for r in db.get("users", {}).values()):
        return
    users = read_users()
    if not users:
        return
    first = users[0]
    db["users"].setdefault(
        first, {"role": "admin", "email": None, "created_at": _now_iso(), "updated_at": _now_iso()}
    )
    db["users"][first]["role"] = "admin"
    write_user_db(db)


def _now_iso() -> str:
    import datetime

    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ─── Endpoints ───────────────────────────────────────────────────

from auth import require_admin  # imported here to avoid circular import at module load


@bp.route("/", endpoint="index")
@require_admin
def index():
    return send_from_directory("/app/static", "index.html")


@bp.route("/api/users", methods=["GET"])
@require_admin
def list_users():
    db = read_user_db()
    users = []
    for u in read_users():
        rec = db.get("users", {}).get(u, {})
        users.append({"username": u, "role": rec.get("role", "user")})
    return jsonify({"users": users})


@bp.route("/api/users", methods=["POST"])
@require_admin
def add_user():
    data = request.get_json() or {}
    username = (data.get("username") or "").strip()
    password = (data.get("password") or "").strip()
    role = (data.get("role") or "user").strip()

    if role not in ("admin", "user"):
        return jsonify({"error": "Role must be 'admin' or 'user'"}), 400
    if not username or not password:
        return jsonify({"error": "Username and password required"}), 400
    if len(username) < 3:
        return jsonify({"error": "Username must be at least 3 characters"}), 400
    if len(password) < 6:
        return jsonify({"error": "Password must be at least 6 characters"}), 400
    if any(c in username for c in "\r\n\t"):
        return jsonify({"error": "Username contains invalid characters"}), 400

    entries = read_entries()
    if any(u == username for u, _ in entries):
        return jsonify({"error": "User already exists"}), 409

    entries.append((username, apr1_hash(password)))
    save_entries(entries)
    set_role(username, role)
    return jsonify({"message": f"User '{username}' created as {role}"})


@bp.route("/api/users/<username>", methods=["DELETE"])
@require_admin
def delete_user(username):
    entries = read_entries()
    new_entries = [(u, h) for u, h in entries if u != username]

    if len(new_entries) == len(entries):
        return jsonify({"error": "User not found"}), 404
    if len(new_entries) == 0:
        return jsonify({"error": "Cannot delete the last user"}), 400

    if get_role(username) == "admin":
        admins = sum(
            1
            for r in read_user_db().get("users", {}).values()
            if r.get("role") == "admin"
        )
        if admins <= 1:
            return jsonify({"error": "Cannot delete the last admin"}), 400

    save_entries(new_entries)
    remove_user_record(username)
    return jsonify({"message": f"User '{username}' deleted"})


@bp.route("/api/users/<username>/password", methods=["PUT"])
@require_admin
def change_password(username):
    data = request.get_json() or {}
    password = (data.get("password") or "").strip()

    if not password:
        return jsonify({"error": "Password required"}), 400
    if len(password) < 6:
        return jsonify({"error": "Password must be at least 6 characters"}), 400

    entries = read_entries()
    found = False
    new_entries = []
    for u, h in entries:
        if u == username:
            new_entries.append((u, apr1_hash(password)))
            found = True
        else:
            new_entries.append((u, h))
    if not found:
        return jsonify({"error": "User not found"}), 404

    save_entries(new_entries)
    return jsonify({"message": f"Password changed for '{username}'"})


@bp.route("/api/users/<username>/role", methods=["PUT"])
@require_admin
def change_role(username):
    data = request.get_json() or {}
    role = (data.get("role") or "").strip()

    if role not in ("admin", "user"):
        return jsonify({"error": "Role must be 'admin' or 'user'"}), 400
    if not any(u == username for u in read_users()):
        return jsonify({"error": "User not found"}), 404
    if get_role(username) == "admin" and role == "user":
        admins = sum(
            1
            for r in read_user_db().get("users", {}).values()
            if r.get("role") == "admin"
        )
        if admins <= 1:
            return jsonify({"error": "Cannot demote the last admin"}), 400

    set_role(username, role)
    return jsonify({"message": f"Role changed to '{role}' for '{username}'"})
```

- [ ] **Step 2: Don't touch `app.py` yet.** Task 7 does the final wiring. For now, run the existing app and confirm nothing has broken (it still uses its own copy of the helpers — we'll cut over after `auth.py` is extracted).

- [ ] **Step 3: Commit (preparation only)**

```bash
git add usermgmt/users.py
git commit -m "refactor: extract users.py blueprint (not yet wired)"
```

---

## Task 7: Extract `auth.py` and reduce `app.py` to a factory

**Files:**
- Create: `usermgmt/auth.py`
- Replace: `usermgmt/app.py`
- Create: `usermgmt/tests/test_auth_existing.py` (sanity tests for the migrated code)

This is the cutover. After this commit, the app behaves exactly as it did before — but the structure is ready for MFA.

- [ ] **Step 1: Create `usermgmt/auth.py`**

```python
"""Session cookie helpers, login/logout/check.

After PR 2 this file grows MFA endpoints. Keeping the surface stable now
makes that addition diffable.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import time
from functools import wraps

from flask import Blueprint, current_app, jsonify, redirect, request, send_from_directory, Response

bp = Blueprint("auth", __name__)


def _config():
    return current_app.config["CONFIG"]


def _sign(payload: str) -> str:
    secret = _config().session_secret.encode()
    return hmac.new(secret, payload.encode(), hashlib.sha256).hexdigest()


def create_session_cookie(username: str, role: str, *, mfa: bool) -> str:
    cfg = _config()
    expires = int(time.time()) + cfg.session_max_age
    payload = json.dumps(
        {"u": username, "r": role, "e": expires, "mfa": mfa},
        separators=(",", ":"),
    )
    sig = _sign(payload)
    return f"{payload}.{sig}"


def validate_session_cookie(cookie: str | None) -> dict | None:
    if not cookie or "." not in cookie:
        return None
    try:
        payload, sig = cookie.rsplit(".", 1)
        if not hmac.compare_digest(sig, _sign(payload)):
            return None
        data = json.loads(payload)
        if data.get("e", 0) < int(time.time()):
            return None
        if _config().mfa_enforced and not data.get("mfa", False):
            return None
        return {"u": data.get("u"), "r": data.get("r", "user")}
    except Exception:
        return None


def get_session_user() -> dict | None:
    return validate_session_cookie(request.cookies.get("kong_session"))


def require_session(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not get_session_user():
            return redirect("/auth/login")
        return f(*args, **kwargs)

    return decorated


def require_admin(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        s = get_session_user()
        if not s:
            return jsonify({"error": "Login required"}), 401
        if s.get("r") != "admin":
            return jsonify({"error": "Admin access required"}), 403
        return f(*args, **kwargs)

    return decorated


# ─── Endpoints ───────────────────────────────────────────────────


@bp.route("/auth/check")
def auth_check():
    s = get_session_user()
    if s:
        resp = Response("OK", 200)
        resp.headers["X-Auth-User"] = s["u"]
        resp.headers["X-Auth-Role"] = s["r"]
        return resp
    return Response("Unauthorized", 401)


@bp.route("/auth/login", methods=["GET"])
def login_page():
    return send_from_directory("/app/static", "login.html")


@bp.route("/auth/login", methods=["POST"])
def login_submit():
    """Password verification only. MFA is added in Task 13."""
    from users import ensure_default_admin, get_role, verify_password

    data = request.get_json(silent=True) or {}
    username = (data.get("username") or "").strip()
    password = (data.get("password") or "").strip()
    if not username or not password:
        return jsonify({"error": "Username and password required"}), 400
    if not verify_password(username, password):
        return jsonify({"error": "Invalid username or password"}), 401

    ensure_default_admin()
    role = get_role(username)
    cookie_val = create_session_cookie(username, role, mfa=False)
    resp = jsonify({"message": "Login successful", "user": username, "role": role})
    resp.set_cookie(
        "kong_session",
        cookie_val,
        max_age=_config().session_max_age,
        httponly=True,
        samesite="Lax",
        path="/",
    )
    return resp


@bp.route("/auth/logout", methods=["GET", "POST"])
def logout():
    resp = redirect("/auth/login")
    resp.delete_cookie("kong_session", path="/")
    return resp


@bp.route("/api/session")
def session_info():
    s = get_session_user()
    if s:
        return jsonify({"authenticated": True, "user": s["u"], "role": s["r"]})
    return jsonify({"authenticated": False}), 401
```

- [ ] **Step 2: Replace `usermgmt/app.py`**

```python
"""Flask factory for kong-usermgmt."""

from __future__ import annotations

from flask import Flask

from config import Config


def create_app() -> Flask:
    app = Flask(__name__)
    cfg = Config.from_env()
    app.config["CONFIG"] = cfg

    from auth import bp as auth_bp
    from users import bp as users_bp

    app.register_blueprint(auth_bp)
    app.register_blueprint(users_bp)

    return app


app = create_app()


if __name__ == "__main__":
    # Development entrypoint only — production runs gunicorn.
    app.run(host="0.0.0.0", port=5000)
```

- [ ] **Step 3: Add a sanity test**

`usermgmt/tests/test_auth_existing.py`:

```python
import json
import os
import subprocess

import pytest

pytestmark = pytest.mark.integration


@pytest.fixture
def app(tmp_data_dir, monkeypatch):
    # Seed htpasswd with one admin
    pw_file = os.environ["HTPASSWD_FILE"]
    subprocess.run(
        ["htpasswd", "-bc", pw_file, "alice", "secret123"],
        check=True, capture_output=True,
    )
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    from app import create_app
    return create_app()


@pytest.fixture
def client(app):
    return app.test_client()


def test_login_returns_cookie(client):
    r = client.post("/auth/login", json={"username": "alice", "password": "secret123"})
    assert r.status_code == 200, r.json
    set_cookie = r.headers.get("Set-Cookie", "")
    assert "kong_session=" in set_cookie


def test_login_wrong_password(client):
    r = client.post("/auth/login", json={"username": "alice", "password": "nope"})
    assert r.status_code == 401


def test_auth_check_requires_session(client):
    r = client.get("/auth/check")
    assert r.status_code == 401


def test_auth_check_with_session(client):
    client.post("/auth/login", json={"username": "alice", "password": "secret123"})
    r = client.get("/auth/check")
    assert r.status_code == 200
    assert r.headers.get("X-Auth-User") == "alice"
    assert r.headers.get("X-Auth-Role") == "admin"
```

Note: `ensure_default_admin` will promote `alice` since she is the first user in htpasswd.

- [ ] **Step 4: Run all tests**

```bash
python -m pytest -v
```

Expected: 12+ passed (storage, config, auth-existing).

- [ ] **Step 5: Smoke test the container**

```bash
docker compose build kong-usermgmt
docker compose up -d kong-usermgmt
sleep 3
curl -sf http://localhost:8888/auth/login > /dev/null && echo "OK"
docker compose down kong-usermgmt
```

Expected: prints `OK`.

- [ ] **Step 6: Commit**

```bash
git add usermgmt/auth.py usermgmt/app.py usermgmt/tests/test_auth_existing.py
git commit -m "refactor: split usermgmt into auth.py + users.py blueprints"
```

PR 1 is now complete. Open a PR titled `refactor: prep for MFA + audit (no behaviour change)`, get review, merge.

---

# PR 2 — Storage + audit foundations

---

## Task 8: `users.json` migration on startup

**Files:**
- Modify: `usermgmt/app.py` (run migration in `create_app`)
- Modify: `usermgmt/users.py` (add `migrate_legacy_roles_file`)
- Create: `usermgmt/tests/test_migration.py`

- [ ] **Step 1: Write failing tests**

`usermgmt/tests/test_migration.py`:

```python
import json
import os

import pytest

from users import migrate_legacy_roles_file


pytestmark = pytest.mark.unit


def test_migration_converts_roles_to_users_db(tmp_data_dir):
    roles_path = os.path.join(tmp_data_dir, "roles.json")
    users_path = os.environ["USERS_FILE"]
    with open(roles_path, "w") as f:
        json.dump({"alice": "admin", "bob": "user"}, f)

    migrate_legacy_roles_file(roles_path)

    with open(users_path) as f:
        db = json.load(f)
    assert db["version"] == 1
    assert db["users"]["alice"]["role"] == "admin"
    assert db["users"]["alice"]["email"] is None
    assert db["users"]["bob"]["role"] == "user"

    # Backup file present
    backups = [f for f in os.listdir(tmp_data_dir) if f.startswith("roles.json.bak-")]
    assert len(backups) == 1


def test_migration_idempotent(tmp_data_dir):
    roles_path = os.path.join(tmp_data_dir, "roles.json")
    users_path = os.environ["USERS_FILE"]
    with open(roles_path, "w") as f:
        json.dump({"alice": "admin"}, f)
    migrate_legacy_roles_file(roles_path)

    # Second migration should be a no-op (users.json already exists)
    migrate_legacy_roles_file(roles_path)

    backups = [f for f in os.listdir(tmp_data_dir) if f.startswith("roles.json.bak-")]
    # Still exactly one backup
    assert len(backups) == 1


def test_migration_no_legacy_file_is_noop(tmp_data_dir):
    roles_path = os.path.join(tmp_data_dir, "roles.json")
    migrate_legacy_roles_file(roles_path)  # must not raise
    assert not os.path.exists(os.environ["USERS_FILE"])
```

- [ ] **Step 2: Implement `migrate_legacy_roles_file` in `usermgmt/users.py`**

Append to `users.py`:

```python
import time as _time


def migrate_legacy_roles_file(roles_path: str) -> None:
    """One-shot migration from roles.json to users.json. Idempotent."""
    users_path = _users_path() if current_app else os.environ["USERS_FILE"]
    if not os.path.exists(roles_path):
        return
    if os.path.exists(users_path):
        return  # already migrated

    with open(roles_path, "r", encoding="utf-8") as f:
        roles = json.load(f)
    now = _now_iso()
    db = {
        "version": 1,
        "users": {
            u: {"role": r, "email": None, "created_at": now, "updated_at": now}
            for u, r in roles.items()
        },
    }
    write_json_file(users_path, db)
    backup = f"{roles_path}.bak-{int(_time.time())}"
    os.replace(roles_path, backup)
```

Add `import json` and `from flask import current_app` to the file's existing imports if not already present.

- [ ] **Step 3: Run tests — they pass**

```bash
python -m pytest tests/test_migration.py -v
```

Expected: 3 passed.

- [ ] **Step 4: Wire migration into `app.py`**

In `create_app()`, after `app.config["CONFIG"] = cfg` and before `register_blueprint`:

```python
from users import migrate_legacy_roles_file
import os.path
roles_legacy = os.path.join(os.path.dirname(cfg.users_file), "roles.json")
migrate_legacy_roles_file(roles_legacy)
```

- [ ] **Step 5: Commit**

```bash
git add usermgmt/users.py usermgmt/app.py usermgmt/tests/test_migration.py
git commit -m "feat: migrate roles.json to users.json on startup"
```

---

## Task 9: `lockouts.py` — password + IP counters

**Files:**
- Create: `usermgmt/lockouts.py`
- Create: `usermgmt/tests/test_lockouts.py`

- [ ] **Step 1: Write failing tests**

`usermgmt/tests/test_lockouts.py`:

```python
import time

import pytest

import lockouts


pytestmark = pytest.mark.unit


@pytest.fixture(autouse=True)
def _config(tmp_data_dir, monkeypatch):
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    from config import Config

    cfg = Config.from_env()
    lockouts.configure(cfg)
    yield cfg


def test_user_lockout_after_threshold():
    for _ in range(5):
        lockouts.record_password_failure("alice")
    assert lockouts.is_user_locked("alice")
    assert not lockouts.is_user_locked("bob")


def test_user_lockout_clears_on_success():
    for _ in range(3):
        lockouts.record_password_failure("alice")
    lockouts.clear_user("alice")
    assert not lockouts.is_user_locked("alice")


def test_user_lockout_expires_after_window(monkeypatch):
    for _ in range(5):
        lockouts.record_password_failure("alice")
    assert lockouts.is_user_locked("alice")
    # Fast-forward 16 minutes
    real_time = time.time
    monkeypatch.setattr(lockouts.time, "time", lambda: real_time() + 16 * 60)
    assert not lockouts.is_user_locked("alice")


def test_ip_mfa_lockout_after_threshold():
    for _ in range(10):
        lockouts.record_mfa_failure("192.168.1.50")
    assert lockouts.is_ip_locked("192.168.1.50")
    assert not lockouts.is_ip_locked("192.168.1.51")


def test_lockouts_persist_across_module_reload(_config):
    for _ in range(5):
        lockouts.record_password_failure("alice")
    assert lockouts.is_user_locked("alice")
    # Simulate process restart by clearing in-memory state
    lockouts._reset_for_tests()
    lockouts.configure(_config)
    assert lockouts.is_user_locked("alice")
```

- [ ] **Step 2: Implement `usermgmt/lockouts.py`**

```python
"""Persistent counters for password failures + MFA-code failures by IP."""

from __future__ import annotations

import time

from storage import read_json_file, with_flock, write_json_file

_cfg = None


def configure(cfg) -> None:
    global _cfg
    _cfg = cfg


def _path() -> str:
    return _cfg.lockouts_file


def _lock() -> str:
    return _path() + ".lock"


def _empty() -> dict:
    return {"users": {}, "ips": {}}


def _load() -> dict:
    return read_json_file(_path(), default=_empty())


def _save(db: dict) -> None:
    write_json_file(_path(), db)


def _reset_for_tests() -> None:
    """Test helper — wipes the on-disk file."""
    import os

    try:
        os.unlink(_path())
    except FileNotFoundError:
        pass


def record_password_failure(username: str) -> None:
    with with_flock(_lock()):
        db = _load()
        rec = db["users"].setdefault(username, {"failed": 0, "locked_until": None})
        rec["failed"] += 1
        rec["last_fail_at"] = int(time.time())
        if rec["failed"] >= _cfg.pwd_lockout_threshold:
            rec["locked_until"] = int(time.time()) + _cfg.pwd_lockout_window_sec
        _save(db)


def is_user_locked(username: str) -> bool:
    db = _load()
    rec = db.get("users", {}).get(username)
    if not rec or not rec.get("locked_until"):
        return False
    if int(time.time()) >= rec["locked_until"]:
        # Window expired — clear in-place
        with with_flock(_lock()):
            db = _load()
            db.get("users", {}).pop(username, None)
            _save(db)
        return False
    return True


def clear_user(username: str) -> None:
    with with_flock(_lock()):
        db = _load()
        db.get("users", {}).pop(username, None)
        _save(db)


def record_mfa_failure(ip: str) -> None:
    with with_flock(_lock()):
        db = _load()
        rec = db["ips"].setdefault(ip, {"mfa_failed": 0, "locked_until": None})
        rec["mfa_failed"] += 1
        rec["last_fail_at"] = int(time.time())
        if rec["mfa_failed"] >= _cfg.ip_mfa_lockout_threshold:
            rec["locked_until"] = int(time.time()) + _cfg.ip_mfa_lockout_window_sec
        _save(db)


def is_ip_locked(ip: str) -> bool:
    db = _load()
    rec = db.get("ips", {}).get(ip)
    if not rec or not rec.get("locked_until"):
        return False
    if int(time.time()) >= rec["locked_until"]:
        with with_flock(_lock()):
            db = _load()
            db.get("ips", {}).pop(ip, None)
            _save(db)
        return False
    return True
```

- [ ] **Step 3: Run tests — they pass**

```bash
python -m pytest tests/test_lockouts.py -v
```

Expected: 5 passed.

- [ ] **Step 4: Configure lockouts at app startup**

In `app.py`'s `create_app`, after `app.config["CONFIG"] = cfg`:

```python
import lockouts
lockouts.configure(cfg)
```

- [ ] **Step 5: Commit**

```bash
git add usermgmt/lockouts.py usermgmt/app.py usermgmt/tests/test_lockouts.py
git commit -m "feat: persistent password + IP lockout counters"
```

---

## Task 10: `audit.py` writer

**Files:**
- Create: `usermgmt/audit.py`
- Create: `usermgmt/tests/test_audit_writer.py`

The retention/rotation thread and viewer are added in T19/T20. This task is just the writer.

- [ ] **Step 1: Write failing tests**

`usermgmt/tests/test_audit_writer.py`:

```python
import datetime
import json
import os

import pytest

import audit


pytestmark = pytest.mark.unit


@pytest.fixture(autouse=True)
def _config(tmp_data_dir, monkeypatch):
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    from config import Config

    cfg = Config.from_env()
    audit.configure(cfg)
    yield cfg


def test_write_appends_jsonl():
    audit.write("login.password.ok", actor="alice", ip="1.2.3.4")
    today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    path = os.path.join(os.environ["AUDIT_DIR"], f"audit-{today}.jsonl")
    with open(path) as f:
        rows = [json.loads(line) for line in f]
    assert len(rows) == 1
    assert rows[0]["event"] == "login.password.ok"
    assert rows[0]["actor"] == "alice"
    assert rows[0]["ip"] == "1.2.3.4"


def test_newline_in_actor_is_escaped():
    audit.write("user.create", actor="bob\nbad", ip="1.2.3.4", target="evil")
    today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    path = os.path.join(os.environ["AUDIT_DIR"], f"audit-{today}.jsonl")
    with open(path) as f:
        lines = f.readlines()
    assert len(lines) == 1
    row = json.loads(lines[0])
    assert row["actor"] == "bob\nbad"


def test_audit_healthy_flips_on_failure(monkeypatch):
    # Point AUDIT_DIR at an unwritable location
    monkeypatch.setattr(audit, "_audit_dir", lambda: "/nope/does/not/exist/forbidden")
    audit.write("startup", actor="system", ip="-")
    assert audit.healthy() is False
```

- [ ] **Step 2: Implement `usermgmt/audit.py`**

```python
"""Append-only JSONL audit writer with health flag."""

from __future__ import annotations

import datetime
import json
import os
import sys
import threading
from typing import Any, Optional

_cfg = None
_lock = threading.Lock()
_healthy = True


def configure(cfg) -> None:
    global _cfg, _healthy
    _cfg = cfg
    _healthy = True
    os.makedirs(_audit_dir(), exist_ok=True)


def _audit_dir() -> str:
    return _cfg.audit_dir


def _today_path() -> str:
    today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    return os.path.join(_audit_dir(), f"audit-{today}.jsonl")


def _now_iso_ms() -> str:
    return (
        datetime.datetime.now(datetime.timezone.utc)
        .strftime("%Y-%m-%dT%H:%M:%S.")
        + f"{datetime.datetime.now(datetime.timezone.utc).microsecond // 1000:03d}Z"
    )


def write(
    event: str,
    *,
    actor: str = "anonymous",
    actor_role: Optional[str] = None,
    ip: str = "-",
    target: Optional[str] = None,
    details: Optional[dict[str, Any]] = None,
) -> None:
    """Best-effort JSONL append. Failures flip the health flag but don't raise."""
    global _healthy
    row = {
        "ts": _now_iso_ms(),
        "actor": actor or "anonymous",
        "actor_role": actor_role,
        "ip": ip or "-",
        "event": event,
        "target": target,
        "details": details or {},
    }
    line = json.dumps(row, separators=(",", ":")) + "\n"
    try:
        with _lock:
            os.makedirs(_audit_dir(), exist_ok=True)
            with open(_today_path(), "a", encoding="utf-8") as f:
                f.write(line)
    except OSError as e:
        _healthy = False
        print(f"[audit] write failed: {e}", file=sys.stderr)


def healthy() -> bool:
    return _healthy
```

- [ ] **Step 3: Run tests — they pass**

```bash
python -m pytest tests/test_audit_writer.py -v
```

Expected: 3 passed.

- [ ] **Step 4: Wire audit into existing call sites**

Edit `usermgmt/auth.py`:

Add `import audit` at the top.

In `login_submit()`, on the wrong-password branch:

```python
if not verify_password(username, password):
    audit.write("login.password.fail", actor=username, ip=request.remote_addr or "-")
    return jsonify({"error": "Invalid username or password"}), 401
```

On the success branch (right before `return resp`):

```python
audit.write(
    "login.password.ok",
    actor=username,
    actor_role=role,
    ip=request.remote_addr or "-",
)
```

In `logout()`:

```python
s = get_session_user()
if s:
    audit.write("logout", actor=s["u"], actor_role=s["r"], ip=request.remote_addr or "-")
```

Edit `usermgmt/users.py` — at the end of each mutating endpoint just before the final `return`, add a one-line audit call:

- `add_user`: `audit.write("user.create", actor=session.get("u"), actor_role="admin", ip=request.remote_addr or "-", target=username, details={"role": role})`
- `delete_user`: `audit.write("user.delete", actor=..., target=username)`
- `change_password`: `audit.write("user.password.change", actor=..., target=username)`
- `change_role`: `audit.write("user.role.change", actor=..., target=username, details={"role": role})`

Use a small helper at the top of `users.py`:

```python
import audit
from auth import get_session_user

def _audit(event, target=None, details=None):
    s = get_session_user() or {"u": "anonymous", "r": None}
    audit.write(event, actor=s["u"], actor_role=s["r"], ip=request.remote_addr or "-",
                target=target, details=details)
```

And replace the verbose `audit.write(...)` calls above with `_audit("user.create", target=username, details={"role": role})` etc.

- [ ] **Step 5: Configure audit at startup**

In `app.py`'s `create_app`, alongside `lockouts.configure(cfg)`:

```python
import audit
audit.configure(cfg)
audit.write("startup", actor="system", ip="-",
            details={"mfa_enforced": cfg.mfa_enforced})
audit.write("mfa.enforced.state", actor="system", ip="-",
            details={"value": cfg.mfa_enforced})
```

- [ ] **Step 6: Add `/healthz` endpoint to `auth.py`**

Append to `auth.py`:

```python
@bp.route("/healthz")
def healthz():
    import audit as a
    return jsonify({"audit_healthy": a.healthy()}), (200 if a.healthy() else 503)
```

- [ ] **Step 7: Run all tests**

```bash
python -m pytest -v
```

Expected: all green.

- [ ] **Step 8: Commit**

```bash
git add usermgmt/audit.py usermgmt/auth.py usermgmt/users.py usermgmt/app.py \
        usermgmt/tests/test_audit_writer.py
git commit -m "feat: audit writer + wire into auth + user-mgmt paths"
```

---

## Task 11: `mailer.py` — SMTP client

**Files:**
- Create: `usermgmt/mailer.py`
- Create: `usermgmt/tests/test_mailer.py`

- [ ] **Step 1: Write failing tests**

`usermgmt/tests/test_mailer.py`:

```python
from unittest.mock import patch, MagicMock

import pytest

import mailer


pytestmark = pytest.mark.unit


@pytest.fixture(autouse=True)
def _config(tmp_data_dir, monkeypatch):
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    from config import Config

    cfg = Config.from_env()
    mailer.configure(cfg)
    return cfg


def test_send_code_uses_email_message():
    with patch("mailer.smtplib.SMTP") as smtp_cls:
        inst = MagicMock()
        smtp_cls.return_value.__enter__.return_value = inst

        mailer.send_mfa_code("alice@example.com", "alice", "123456")

        smtp_cls.assert_called_once_with("mail.internal", 587, timeout=10)
        inst.starttls.assert_called_once()
        inst.send_message.assert_called_once()
        msg = inst.send_message.call_args[0][0]
        assert "123456" in msg.get_content()
        assert msg["To"] == "alice@example.com"
        assert msg["Subject"].startswith("SEHC AI Gateway")


def test_send_code_optional_auth():
    with patch("mailer.smtplib.SMTP") as smtp_cls:
        inst = MagicMock()
        smtp_cls.return_value.__enter__.return_value = inst

        mailer.send_mfa_code("alice@example.com", "alice", "654321")

        # No username/pass set → no login call
        inst.login.assert_not_called()


def test_send_code_with_auth(monkeypatch):
    monkeypatch.setenv("SMTP_USER", "relay")
    monkeypatch.setenv("SMTP_PASS", "secret")
    from config import Config

    mailer.configure(Config.from_env())

    with patch("mailer.smtplib.SMTP") as smtp_cls:
        inst = MagicMock()
        smtp_cls.return_value.__enter__.return_value = inst

        mailer.send_mfa_code("alice@example.com", "alice", "111111")
        inst.login.assert_called_once_with("relay", "secret")


def test_send_code_raises_on_smtp_failure():
    with patch("mailer.smtplib.SMTP", side_effect=ConnectionRefusedError("no relay")):
        with pytest.raises(mailer.MailerError):
            mailer.send_mfa_code("alice@example.com", "alice", "000000")
```

- [ ] **Step 2: Implement `usermgmt/mailer.py`**

```python
"""SMTP client for MFA codes. Uses EmailMessage to avoid header injection."""

from __future__ import annotations

import smtplib
from email.message import EmailMessage

_cfg = None


class MailerError(Exception):
    pass


def configure(cfg) -> None:
    global _cfg
    _cfg = cfg


_TEMPLATE = """Hello {username},

Your one-time verification code is:

    {code}

It expires in 5 minutes. If you didn't try to sign in, ignore this email
and contact your administrator.

— SEHC AI Gateway
"""


def send_mfa_code(to_email: str, username: str, code: str) -> None:
    msg = EmailMessage()
    msg["From"] = _cfg.smtp_from
    msg["To"] = to_email
    msg["Subject"] = "SEHC AI Gateway — your verification code"
    msg.set_content(_TEMPLATE.format(username=username, code=code))
    try:
        with smtplib.SMTP(_cfg.smtp_host, _cfg.smtp_port, timeout=_cfg.smtp_timeout_sec) as s:
            if _cfg.smtp_use_tls:
                s.starttls()
            if _cfg.smtp_user and _cfg.smtp_pass:
                s.login(_cfg.smtp_user, _cfg.smtp_pass)
            s.send_message(msg)
    except (smtplib.SMTPException, OSError) as e:
        raise MailerError(str(e)) from e
```

- [ ] **Step 3: Run tests — they pass**

```bash
python -m pytest tests/test_mailer.py -v
```

Expected: 4 passed.

- [ ] **Step 4: Configure mailer at startup**

In `app.py`'s `create_app`:

```python
import mailer
mailer.configure(cfg)
```

- [ ] **Step 5: Commit**

```bash
git add usermgmt/mailer.py usermgmt/app.py usermgmt/tests/test_mailer.py
git commit -m "feat: SMTP mailer for MFA codes"
```

PR 2 is now complete. Open `feat: storage, lockouts, audit writer, mailer (no UX change yet)`. Merge before PR 3.

---

# PR 3 — MFA login flow

---

## Task 12: Email field on users + endpoints

**Files:**
- Modify: `usermgmt/users.py` (extend `add_user`, add `change_email`)
- Modify: `usermgmt/static/index.html` (admin UI shows + edits email — minimal change)
- Create: `usermgmt/tests/test_users_email.py`

- [ ] **Step 1: Write failing tests**

`usermgmt/tests/test_users_email.py`:

```python
import os
import subprocess

import pytest


pytestmark = pytest.mark.integration


@pytest.fixture
def client(tmp_data_dir, monkeypatch):
    pw_file = os.environ["HTPASSWD_FILE"]
    subprocess.run(["htpasswd", "-bc", pw_file, "alice", "secret123"], check=True, capture_output=True)
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    from app import create_app
    app = create_app()
    c = app.test_client()
    c.post("/auth/login", json={"username": "alice", "password": "secret123"})
    return c


def test_add_user_with_email(client):
    r = client.post("/api/users", json={
        "username": "bob", "password": "secret789",
        "role": "user", "email": "bob@example.com"
    })
    assert r.status_code == 200


def test_add_user_rejects_newline_in_email(client):
    r = client.post("/api/users", json={
        "username": "bob", "password": "secret789",
        "role": "user", "email": "bob@example.com\nBcc: evil@x"
    })
    assert r.status_code == 400


def test_change_email(client):
    client.post("/api/users", json={
        "username": "bob", "password": "secret789",
        "role": "user", "email": "bob@example.com"
    })
    r = client.put("/api/users/bob/email", json={"email": "bob2@example.com"})
    assert r.status_code == 200
    listing = client.get("/api/users").json["users"]
    bob = next(u for u in listing if u["username"] == "bob")
    assert bob["email"] == "bob2@example.com"
```

- [ ] **Step 2: Update `users.py`**

In `add_user`, before `entries.append(...)`:

```python
email = (data.get("email") or "").strip()
if email and not _valid_email(email):
    return jsonify({"error": "Invalid email"}), 400
```

And after creating the user, set the email:

```python
if email:
    _set_email(username, email)
```

Add helpers near `_now_iso`:

```python
import re

_EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$")


def _valid_email(email: str) -> bool:
    if any(c in email for c in "\r\n\t"):
        return False
    if not (5 <= len(email) <= 254):
        return False
    return bool(_EMAIL_RE.match(email))


def _set_email(username: str, email: str) -> None:
    db = read_user_db()
    rec = db["users"].setdefault(
        username, {"role": "user", "email": None, "created_at": _now_iso(), "updated_at": _now_iso()}
    )
    rec["email"] = email
    rec["updated_at"] = _now_iso()
    write_user_db(db)


def get_email(username: str) -> str | None:
    return read_user_db().get("users", {}).get(username, {}).get("email")
```

Update `list_users` to include email:

```python
users.append({"username": u, "role": rec.get("role", "user"), "email": rec.get("email")})
```

Add the change-email endpoint:

```python
@bp.route("/api/users/<username>/email", methods=["PUT"])
@require_admin
def change_email(username):
    data = request.get_json() or {}
    email = (data.get("email") or "").strip()
    if not _valid_email(email):
        return jsonify({"error": "Invalid email"}), 400
    if username not in read_user_db().get("users", {}) and username not in read_users():
        return jsonify({"error": "User not found"}), 404
    _set_email(username, email)
    _audit("user.email.change", target=username)
    return jsonify({"message": f"Email updated for '{username}'"})
```

- [ ] **Step 3: Run tests — they pass**

```bash
python -m pytest tests/test_users_email.py -v
```

Expected: 3 passed.

- [ ] **Step 4: Update `index.html`** — add an Email column to the users table, and a small inline-edit affordance. Keep changes minimal; the design doesn't require a UI overhaul. Detailed HTML diff in the PR description.

Minimum change: in the existing user list rendering JS, add `<td>${u.email || ''}</td>` and a small "Edit email" button calling `PUT /api/users/<u>/email`.

- [ ] **Step 5: Commit**

```bash
git add usermgmt/users.py usermgmt/static/index.html usermgmt/tests/test_users_email.py
git commit -m "feat: store and edit per-user email addresses"
```

---

## Task 13: MFA step 1 — `POST /auth/login` returns challenge

**Files:**
- Modify: `usermgmt/auth.py`
- Create: `usermgmt/mfa.py` (challenge storage)
- Create: `usermgmt/tests/test_mfa_login.py`

- [ ] **Step 1: Write failing tests**

`usermgmt/tests/test_mfa_login.py`:

```python
import os
import subprocess
from unittest.mock import patch

import pytest


pytestmark = pytest.mark.integration


@pytest.fixture
def client(tmp_data_dir, monkeypatch):
    pw_file = os.environ["HTPASSWD_FILE"]
    subprocess.run(["htpasswd", "-bc", pw_file, "alice", "secret123"], check=True, capture_output=True)
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    monkeypatch.setenv("MFA_ENFORCED", "true")
    from app import create_app
    app = create_app()
    c = app.test_client()
    # Seed email
    # Have to log in first to set it — but MFA is enforced…
    # Use the bootstrap path: drop a users.json with alice as admin + email.
    import json
    with open(os.environ["USERS_FILE"], "w") as f:
        json.dump({"version": 1, "users": {"alice": {
            "role": "admin", "email": "alice@example.com",
            "created_at": "now", "updated_at": "now"}}}, f)
    return c


def test_login_step1_returns_challenge(client):
    with patch("mailer.send_mfa_code") as send:
        r = client.post("/auth/login",
                        json={"username": "alice", "password": "secret123"},
                        headers={"X-Real-IP": "192.168.1.50"})
    assert r.status_code == 200
    body = r.json
    assert body["step"] == "mfa_required"
    assert "challenge_id" in body
    assert body["masked_email"].startswith("a")
    assert "@" in body["masked_email"]
    assert send.called


def test_login_step1_no_cookie_yet(client):
    with patch("mailer.send_mfa_code"):
        r = client.post("/auth/login",
                        json={"username": "alice", "password": "secret123"},
                        headers={"X-Real-IP": "192.168.1.50"})
    assert "kong_session" not in r.headers.get("Set-Cookie", "")


def test_login_step1_smtp_failure_returns_503(client):
    from mailer import MailerError
    with patch("mailer.send_mfa_code", side_effect=MailerError("relay down")):
        r = client.post("/auth/login",
                        json={"username": "alice", "password": "secret123"},
                        headers={"X-Real-IP": "192.168.1.50"})
    assert r.status_code == 503


def test_login_step1_no_email_returns_409(client):
    import json
    with open(os.environ["USERS_FILE"], "w") as f:
        json.dump({"version": 1, "users": {"alice": {
            "role": "admin", "email": None,
            "created_at": "now", "updated_at": "now"}}}, f)
    r = client.post("/auth/login",
                    json={"username": "alice", "password": "secret123"},
                    headers={"X-Real-IP": "192.168.1.50"})
    assert r.status_code == 409


def test_mfa_disabled_skips_challenge_and_sets_cookie(client, monkeypatch):
    monkeypatch.setenv("MFA_ENFORCED", "false")
    # Re-create the app with new env
    from app import create_app
    c = create_app().test_client()
    r = c.post("/auth/login",
               json={"username": "alice", "password": "secret123"},
               headers={"X-Real-IP": "192.168.1.50"})
    assert r.status_code == 200
    assert r.json.get("step") == "ok"
    assert "kong_session" in r.headers.get("Set-Cookie", "")
```

- [ ] **Step 2: Create `usermgmt/mfa.py`**

```python
"""Active MFA challenges. Persisted to mfa_state.json with flock + atomic write."""

from __future__ import annotations

import hashlib
import hmac
import secrets
import time

from storage import read_json_file, with_flock, write_json_file

_cfg = None


def configure(cfg) -> None:
    global _cfg
    _cfg = cfg


def _path() -> str:
    return _cfg.mfa_state_file


def _lock() -> str:
    return _path() + ".lock"


def _load() -> dict:
    return read_json_file(_path(), default={})


def _save(state: dict) -> None:
    write_json_file(_path(), state)


def _hmac(code: str) -> str:
    return hmac.new(_cfg.session_secret.encode(), code.encode(), hashlib.sha256).hexdigest()


def _gc(state: dict) -> dict:
    now = int(time.time())
    return {cid: c for cid, c in state.items() if c.get("expires_at", 0) > now}


def issue_challenge(username: str, ip: str) -> tuple[str, str]:
    """Returns (challenge_id, code). Caller is responsible for emailing the code."""
    code = f"{secrets.randbelow(1_000_000):06d}"
    challenge_id = secrets.token_urlsafe(24)
    with with_flock(_lock()):
        state = _gc(_load())
        state[challenge_id] = {
            "username": username,
            "code_hmac": _hmac(code),
            "expires_at": int(time.time()) + _cfg.mfa_code_ttl_sec,
            "attempts_left": _cfg.mfa_max_attempts,
            "bound_ip": ip,
            "created_at": int(time.time()),
            "resends_left": 1,
            "last_sent_at": int(time.time()),
        }
        _save(state)
    return challenge_id, code


def get_challenge(challenge_id: str) -> dict | None:
    state = _gc(_load())
    return state.get(challenge_id)


def consume_challenge(challenge_id: str) -> None:
    with with_flock(_lock()):
        state = _load()
        state.pop(challenge_id, None)
        _save(state)


def fail_challenge(challenge_id: str) -> int:
    """Decrement attempts_left. Delete if zero. Returns remaining attempts."""
    with with_flock(_lock()):
        state = _load()
        rec = state.get(challenge_id)
        if not rec:
            return 0
        rec["attempts_left"] -= 1
        if rec["attempts_left"] <= 0:
            state.pop(challenge_id, None)
            _save(state)
            return 0
        _save(state)
        return rec["attempts_left"]


def verify_code(challenge_id: str, code: str) -> bool:
    rec = get_challenge(challenge_id)
    if not rec:
        return False
    return hmac.compare_digest(rec["code_hmac"], _hmac(code))


def reissue_code(challenge_id: str) -> str | None:
    """Resend path. Returns the new code, or None if not allowed."""
    with with_flock(_lock()):
        state = _load()
        rec = state.get(challenge_id)
        if not rec:
            return None
        now = int(time.time())
        if rec["resends_left"] <= 0:
            return None
        if now - rec["last_sent_at"] < _cfg.mfa_resend_cooldown_sec:
            return None
        new_code = f"{secrets.randbelow(1_000_000):06d}"
        rec["code_hmac"] = _hmac(new_code)
        rec["expires_at"] = now + _cfg.mfa_code_ttl_sec
        rec["attempts_left"] = _cfg.mfa_max_attempts
        rec["resends_left"] -= 1
        rec["last_sent_at"] = now
        _save(state)
        return new_code
```

- [ ] **Step 3: Update `auth.py` — `login_submit`**

Replace the existing implementation with:

```python
def _client_ip() -> str:
    # Trust X-Real-IP only (set by nginx from $remote_addr). Never X-Forwarded-For.
    return request.headers.get("X-Real-IP") or (request.remote_addr or "-")


def _mask_email(email: str) -> str:
    try:
        local, domain = email.split("@", 1)
        dot = domain.find(".")
        d_head, d_tail = (domain[:dot], domain[dot:]) if dot >= 0 else (domain, "")
        return f"{local[0]}***@{d_head[0]}***{d_tail}"
    except Exception:
        return "***"


@bp.route("/auth/login", methods=["POST"])
def login_submit():
    import audit, lockouts, mailer, mfa
    from users import ensure_default_admin, get_email, get_role, verify_password

    cfg = _config()
    data = request.get_json(silent=True) or {}
    username = (data.get("username") or "").strip()
    password = (data.get("password") or "").strip()
    ip = _client_ip()
    if not username or not password:
        return jsonify({"error": "Username and password required"}), 400

    if lockouts.is_user_locked(username):
        audit.write("login.locked.user", actor=username, ip=ip)
        return jsonify({"error": "Account locked. Try again later."}), 423
    if lockouts.is_ip_locked(ip):
        audit.write("login.locked.ip", actor=username, ip=ip)
        return jsonify({"error": "Too many failed attempts. Try again later."}), 423

    if not verify_password(username, password):
        lockouts.record_password_failure(username)
        audit.write("login.password.fail", actor=username, ip=ip)
        return jsonify({"error": "Invalid username or password"}), 401

    ensure_default_admin()
    role = get_role(username)
    audit.write("login.password.ok", actor=username, actor_role=role, ip=ip)

    if not cfg.mfa_enforced:
        audit.write("login.bypass.mfa_disabled", actor=username, actor_role=role, ip=ip)
        audit.write("login.success", actor=username, actor_role=role, ip=ip)
        cookie_val = create_session_cookie(username, role, mfa=False)
        resp = jsonify({"step": "ok", "user": username, "role": role,
                        "message": "Login successful"})
        resp.set_cookie("kong_session", cookie_val, max_age=cfg.session_max_age,
                        httponly=True, samesite="Strict", path="/")
        return resp

    email = get_email(username)
    if not email:
        audit.write("login.no_email", actor=username, actor_role=role, ip=ip)
        return jsonify({"error": "No email on file. Contact your administrator."}), 409

    challenge_id, code = mfa.issue_challenge(username, ip)
    try:
        mailer.send_mfa_code(email, username, code)
    except mailer.MailerError as e:
        mfa.consume_challenge(challenge_id)
        audit.write("login.mfa.send_fail", actor=username, ip=ip,
                    details={"reason": str(e)[:120]})
        return jsonify({"error": "Could not send verification email. Try again shortly."}), 503

    audit.write("login.mfa.sent", actor=username, actor_role=role, ip=ip,
                details={"challenge_id": challenge_id})

    return jsonify({"step": "mfa_required",
                    "challenge_id": challenge_id,
                    "masked_email": _mask_email(email),
                    "expires_in": cfg.mfa_code_ttl_sec})
```

- [ ] **Step 4: Configure mfa at startup**

In `app.py`'s `create_app`:

```python
import mfa
mfa.configure(cfg)
```

- [ ] **Step 5: Run tests**

```bash
python -m pytest tests/test_mfa_login.py -v
```

Expected: 5 passed.

- [ ] **Step 6: Commit**

```bash
git add usermgmt/mfa.py usermgmt/auth.py usermgmt/app.py usermgmt/tests/test_mfa_login.py
git commit -m "feat: MFA step 1 — challenge issued after password"
```

---

## Task 14: MFA step 2 — `POST /auth/mfa` verifies code

**Files:**
- Modify: `usermgmt/auth.py`
- Create: `usermgmt/tests/test_mfa_verify.py`

- [ ] **Step 1: Write failing tests**

`usermgmt/tests/test_mfa_verify.py`:

```python
import json
import os
import subprocess
from unittest.mock import patch

import pytest


pytestmark = pytest.mark.integration


@pytest.fixture
def env(tmp_data_dir, monkeypatch):
    pw_file = os.environ["HTPASSWD_FILE"]
    subprocess.run(["htpasswd", "-bc", pw_file, "alice", "secret123"],
                   check=True, capture_output=True)
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    monkeypatch.setenv("MFA_ENFORCED", "true")
    with open(os.environ["USERS_FILE"], "w") as f:
        json.dump({"version": 1, "users": {"alice": {
            "role": "admin", "email": "alice@example.com",
            "created_at": "now", "updated_at": "now"}}}, f)


def _start_login(client, ip="192.168.1.50"):
    captured = {}
    def fake_send(to, user, code):
        captured["code"] = code
    with patch("mailer.send_mfa_code", side_effect=fake_send):
        r = client.post("/auth/login",
                        json={"username": "alice", "password": "secret123"},
                        headers={"X-Real-IP": ip})
    return r.json["challenge_id"], captured["code"]


@pytest.fixture
def client(env):
    from app import create_app
    return create_app().test_client()


def test_mfa_verify_success(client):
    chal, code = _start_login(client)
    r = client.post("/auth/mfa",
                    json={"challenge_id": chal, "code": code},
                    headers={"X-Real-IP": "192.168.1.50"})
    assert r.status_code == 200
    assert "kong_session" in r.headers.get("Set-Cookie", "")


def test_mfa_verify_wrong_code(client):
    chal, code = _start_login(client)
    r = client.post("/auth/mfa",
                    json={"challenge_id": chal, "code": "000000"},
                    headers={"X-Real-IP": "192.168.1.50"})
    assert r.status_code == 401
    assert r.json.get("attempts_left") == 2


def test_mfa_three_wrong_codes_kills_challenge(client):
    chal, code = _start_login(client)
    for _ in range(3):
        client.post("/auth/mfa", json={"challenge_id": chal, "code": "000000"},
                    headers={"X-Real-IP": "192.168.1.50"})
    # Fourth try with the right code is now too late
    r = client.post("/auth/mfa", json={"challenge_id": chal, "code": code},
                    headers={"X-Real-IP": "192.168.1.50"})
    assert r.status_code == 410


def test_mfa_ip_mismatch_rejected(client):
    chal, code = _start_login(client, ip="192.168.1.50")
    r = client.post("/auth/mfa", json={"challenge_id": chal, "code": code},
                    headers={"X-Real-IP": "192.168.1.51"})
    assert r.status_code == 401


def test_ip_lockout_after_10_failures(client):
    chal, _ = _start_login(client)
    for _ in range(3):
        client.post("/auth/mfa", json={"challenge_id": chal, "code": "000000"},
                    headers={"X-Real-IP": "192.168.1.50"})
    # Issue another challenge and burn through more code attempts
    chal2, _ = _start_login(client)
    for _ in range(3):
        client.post("/auth/mfa", json={"challenge_id": chal2, "code": "000000"},
                    headers={"X-Real-IP": "192.168.1.50"})
    chal3, _ = _start_login(client)
    for _ in range(4):
        client.post("/auth/mfa", json={"challenge_id": chal3, "code": "000000"},
                    headers={"X-Real-IP": "192.168.1.50"})
    # Next login attempt from this IP — locked
    r = client.post("/auth/login",
                    json={"username": "alice", "password": "secret123"},
                    headers={"X-Real-IP": "192.168.1.50"})
    assert r.status_code == 423
```

- [ ] **Step 2: Add the endpoint to `auth.py`**

```python
@bp.route("/auth/mfa", methods=["POST"])
def mfa_submit():
    import audit, lockouts, mfa
    from users import get_role

    cfg = _config()
    data = request.get_json(silent=True) or {}
    challenge_id = (data.get("challenge_id") or "").strip()
    code = (data.get("code") or "").strip()
    ip = _client_ip()

    if lockouts.is_ip_locked(ip):
        audit.write("login.locked.ip", actor="anonymous", ip=ip)
        return jsonify({"error": "Too many failed attempts. Try again later."}), 423

    rec = mfa.get_challenge(challenge_id)
    if not rec:
        audit.write("login.mfa.expired", actor="anonymous", ip=ip,
                    details={"challenge_id": challenge_id})
        return jsonify({"error": "Code expired. Please log in again."}), 410

    if rec["bound_ip"] != ip:
        mfa.consume_challenge(challenge_id)
        audit.write("login.mfa.fail", actor=rec.get("username", "anonymous"),
                    ip=ip, details={"reason": "ip_mismatch"})
        return jsonify({"error": "Invalid code"}), 401

    if not mfa.verify_code(challenge_id, code):
        lockouts.record_mfa_failure(ip)
        remaining = mfa.fail_challenge(challenge_id)
        audit.write("login.mfa.fail", actor=rec["username"], ip=ip,
                    details={"attempts_left": remaining})
        if remaining == 0:
            return jsonify({"error": "Code expired. Please log in again."}), 410
        return jsonify({"error": "Invalid code", "attempts_left": remaining}), 401

    username = rec["username"]
    role = get_role(username)
    mfa.consume_challenge(challenge_id)
    lockouts.clear_user(username)

    audit.write("login.mfa.ok", actor=username, actor_role=role, ip=ip)
    audit.write("login.success", actor=username, actor_role=role, ip=ip)

    cookie_val = create_session_cookie(username, role, mfa=True)
    resp = jsonify({"message": "Login successful", "user": username, "role": role})
    resp.set_cookie("kong_session", cookie_val, max_age=cfg.session_max_age,
                    httponly=True, samesite="Strict", path="/")
    return resp
```

- [ ] **Step 3: Run tests**

```bash
python -m pytest tests/test_mfa_verify.py -v
```

Expected: 5 passed.

- [ ] **Step 4: Commit**

```bash
git add usermgmt/auth.py usermgmt/tests/test_mfa_verify.py
git commit -m "feat: MFA step 2 — verify code, issue session"
```

---

## Task 15: MFA resend

**Files:**
- Modify: `usermgmt/auth.py`
- Create: `usermgmt/tests/test_mfa_resend.py`

- [ ] **Step 1: Write failing tests**

`usermgmt/tests/test_mfa_resend.py`:

```python
import json
import os
import subprocess
import time
from unittest.mock import patch

import pytest


pytestmark = pytest.mark.integration


@pytest.fixture
def client(tmp_data_dir, monkeypatch):
    pw_file = os.environ["HTPASSWD_FILE"]
    subprocess.run(["htpasswd", "-bc", pw_file, "alice", "secret123"],
                   check=True, capture_output=True)
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    monkeypatch.setenv("MFA_ENFORCED", "true")
    monkeypatch.setenv("MFA_RESEND_COOLDOWN_SEC", "0")
    with open(os.environ["USERS_FILE"], "w") as f:
        json.dump({"version": 1, "users": {"alice": {
            "role": "admin", "email": "alice@example.com",
            "created_at": "n", "updated_at": "n"}}}, f)
    from app import create_app
    return create_app().test_client()


def _start(client):
    codes = []
    def cap(to, user, code):
        codes.append(code)
    p = patch("mailer.send_mfa_code", side_effect=cap)
    p.start()
    r = client.post("/auth/login",
                    json={"username": "alice", "password": "secret123"},
                    headers={"X-Real-IP": "192.168.1.50"})
    return r.json["challenge_id"], codes, p


def test_resend_returns_new_code(client):
    chal, codes, p = _start(client)
    r = client.post("/auth/mfa/resend",
                    json={"challenge_id": chal},
                    headers={"X-Real-IP": "192.168.1.50"})
    p.stop()
    assert r.status_code == 200
    assert len(codes) == 2
    assert codes[0] != codes[1]


def test_resend_invalidates_old_code(client):
    chal, codes, p = _start(client)
    client.post("/auth/mfa/resend",
                json={"challenge_id": chal},
                headers={"X-Real-IP": "192.168.1.50"})
    # Old code should now be invalid
    r = client.post("/auth/mfa",
                    json={"challenge_id": chal, "code": codes[0]},
                    headers={"X-Real-IP": "192.168.1.50"})
    p.stop()
    assert r.status_code == 401


def test_resend_only_once(client):
    chal, _codes, p = _start(client)
    r1 = client.post("/auth/mfa/resend", json={"challenge_id": chal},
                     headers={"X-Real-IP": "192.168.1.50"})
    r2 = client.post("/auth/mfa/resend", json={"challenge_id": chal},
                     headers={"X-Real-IP": "192.168.1.50"})
    p.stop()
    assert r1.status_code == 200
    assert r2.status_code == 429
```

- [ ] **Step 2: Add the endpoint to `auth.py`**

```python
@bp.route("/auth/mfa/resend", methods=["POST"])
def mfa_resend():
    import audit, mailer, mfa
    from users import get_email

    data = request.get_json(silent=True) or {}
    challenge_id = (data.get("challenge_id") or "").strip()
    ip = _client_ip()

    rec = mfa.get_challenge(challenge_id)
    if not rec:
        return jsonify({"error": "Challenge expired"}), 410
    if rec["bound_ip"] != ip:
        return jsonify({"error": "Invalid challenge"}), 401

    new_code = mfa.reissue_code(challenge_id)
    if new_code is None:
        return jsonify({"error": "Resend not allowed"}), 429

    email = get_email(rec["username"]) or ""
    try:
        mailer.send_mfa_code(email, rec["username"], new_code)
    except mailer.MailerError as e:
        audit.write("login.mfa.send_fail", actor=rec["username"], ip=ip,
                    details={"reason": str(e)[:120], "resend": True})
        return jsonify({"error": "Could not send verification email."}), 503

    audit.write("login.mfa.sent", actor=rec["username"], ip=ip,
                details={"challenge_id": challenge_id, "resend": True})
    return jsonify({"message": "Code resent"})
```

- [ ] **Step 3: Run tests**

```bash
python -m pytest tests/test_mfa_resend.py -v
```

Expected: 3 passed.

- [ ] **Step 4: Commit**

```bash
git add usermgmt/auth.py usermgmt/tests/test_mfa_resend.py
git commit -m "feat: MFA resend endpoint"
```

---

## Task 16: Session cookie `mfa` claim + flag-flip invalidation

**Files:**
- (no code change — claim was already added in T7's `create_session_cookie` and T7's `validate_session_cookie`)
- Create: `usermgmt/tests/test_mfa_claim.py`

- [ ] **Step 1: Write failing test**

`usermgmt/tests/test_mfa_claim.py`:

```python
import json
import os
import subprocess

import pytest


pytestmark = pytest.mark.integration


@pytest.fixture
def client_factory(tmp_data_dir, monkeypatch):
    pw = os.environ["HTPASSWD_FILE"]
    subprocess.run(["htpasswd", "-bc", pw, "alice", "secret123"], check=True, capture_output=True)
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    with open(os.environ["USERS_FILE"], "w") as f:
        json.dump({"version": 1, "users": {"alice": {
            "role": "admin", "email": "a@b.c",
            "created_at": "n", "updated_at": "n"}}}, f)
    def make():
        from importlib import reload
        import config, app as appmod
        reload(config); reload(appmod)
        return appmod.create_app().test_client()
    return make


def test_mfa_false_cookie_rejected_after_flag_flip(client_factory, monkeypatch):
    monkeypatch.setenv("MFA_ENFORCED", "false")
    c1 = client_factory()
    r = c1.post("/auth/login",
                json={"username": "alice", "password": "secret123"},
                headers={"X-Real-IP": "192.168.1.50"})
    cookie = r.headers.get("Set-Cookie", "")
    assert "kong_session=" in cookie
    # Extract the cookie value
    raw = cookie.split("kong_session=", 1)[1].split(";", 1)[0]

    # Flip the flag, create a new app, send the old cookie
    monkeypatch.setenv("MFA_ENFORCED", "true")
    c2 = client_factory()
    c2.set_cookie("localhost", "kong_session", raw)
    r2 = c2.get("/auth/check")
    assert r2.status_code == 401
```

- [ ] **Step 2: Confirm test passes against existing implementation**

The behaviour was wired in T7's `validate_session_cookie` — but the test forces it through the real config flip. Run:

```bash
python -m pytest tests/test_mfa_claim.py -v
```

Expected: 1 passed. If it fails, the bug is in `validate_session_cookie`'s `if _config().mfa_enforced and not data.get("mfa", False):` check — fix that line.

- [ ] **Step 3: Commit**

```bash
git add usermgmt/tests/test_mfa_claim.py
git commit -m "test: backfill-era cookies invalidated once MFA enforced"
```

PR 3 is now complete. Open `feat: email MFA login flow`. Reviewer checklist must include manual SMTP roundtrip against the internal relay. Merge.

---

# PR 4 — Audit viewer + nginx + login rebrand

---

## Task 17: nginx — JSON access log + `auth_request_set`

**Files:**
- Modify: `nginx/default.conf`

- [ ] **Step 1: Edit `nginx/default.conf`**

At the top (above `server {`):

```nginx
log_format audit_json escape=json
  '{"ts":"$time_iso8601","actor":"$auth_user","actor_role":"$auth_role",'
  '"ip":"$remote_addr","event":"kong.api.request","target":null,'
  '"details":{"method":"$request_method","path":"$request_uri",'
  '"status":$status,"bytes":$body_bytes_sent,"ms":$request_time}}';
```

Inside the existing `location /api/ { ... }` block, after the `auth_request /_auth_check;` line:

```nginx
auth_request_set $auth_user  $upstream_http_x_auth_user;
auth_request_set $auth_role  $upstream_http_x_auth_role;
access_log /var/log/audit/access-current.jsonl audit_json;
```

Inside the existing `location /users/ { ... }` block, after `auth_request`:

```nginx
auth_request_set $auth_user  $upstream_http_x_auth_user;
auth_request_set $auth_role  $upstream_http_x_auth_role;
```

(no access_log line for `/users/` — those events come from Flask's `audit-*.jsonl`)

- [ ] **Step 2: Pass X-Real-IP into Flask explicitly**

In every Flask-proxying location block (the `/auth/`, `/users/`, and the new `/logs/` from T18), add (or confirm present):

```nginx
proxy_set_header X-Real-IP $remote_addr;
```

Already set in the existing config — verify and leave alone if so.

- [ ] **Step 3: Restart nginx**

```bash
docker compose restart kong-auth-proxy
docker compose logs --tail 30 kong-auth-proxy
```

Expected: no startup errors.

- [ ] **Step 4: Smoke test**

```bash
# Trigger a /api/ call after logging in via the browser, then:
ls -la /DATA/kong/data/audit/
tail -n 5 /DATA/kong/data/audit/access-current.jsonl
```

Expected: file exists, one JSON object per line.

- [ ] **Step 5: Commit**

```bash
git add nginx/default.conf
git commit -m "feat: nginx writes JSON access log for /api/ with user identity"
```

---

## Task 18: nginx — CORS lockdown + `/logs/` location

**Files:**
- Modify: `nginx/default.conf`

- [ ] **Step 1: Replace the CORS block inside `location /api/`**

Replace:

```nginx
add_header 'Access-Control-Allow-Origin' $http_origin always;
add_header 'Access-Control-Allow-Credentials' 'true' always;
```

(and the matching block inside the OPTIONS branch)

with:

```nginx
add_header 'Access-Control-Allow-Origin' 'http://192.168.1.121:8002' always;
add_header 'Access-Control-Allow-Credentials' 'true' always;
```

(and the OPTIONS branch matches: also use the static origin).

If the deployment will be accessed via a different origin, document this in `.env.example` and parameterise via an `envsubst`-rendered config — out of scope here; keep the static origin for now.

- [ ] **Step 2: Add the `/logs/` location block** (immediately below `/users/`):

```nginx
location /logs/ {
    auth_request /_auth_check;
    error_page 401 = @login_redirect;

    auth_request_set $auth_user  $upstream_http_x_auth_user;
    auth_request_set $auth_role  $upstream_http_x_auth_role;

    proxy_pass http://kong-usermgmt:5000/logs/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header Cookie $http_cookie;
    proxy_set_header Authorization "";
}
```

- [ ] **Step 3: Restart and verify**

```bash
docker compose restart kong-auth-proxy
```

Expected: clean restart.

- [ ] **Step 4: Commit**

```bash
git add nginx/default.conf
git commit -m "feat: lock CORS to host origin, add /logs/ location"
```

---

## Task 19: Audit retention + nginx rotation thread

**Files:**
- Modify: `usermgmt/audit.py` (add retention + rotation)
- Modify: `usermgmt/app.py` (start the thread)
- Create: `usermgmt/tests/test_audit_retention.py`

- [ ] **Step 1: Write failing test**

`usermgmt/tests/test_audit_retention.py`:

```python
import datetime
import os

import pytest

import audit


pytestmark = pytest.mark.unit


@pytest.fixture(autouse=True)
def _cfg(tmp_data_dir, monkeypatch):
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    from config import Config

    cfg = Config.from_env()
    audit.configure(cfg)
    yield cfg


def _make_file(name, days_old):
    path = os.path.join(os.environ["AUDIT_DIR"], name)
    with open(path, "w") as f:
        f.write("{}\n")
    ts = datetime.datetime.now().timestamp() - days_old * 86400
    os.utime(path, (ts, ts))
    return path


def test_retention_deletes_old_files():
    keep = _make_file("audit-2026-05-20.jsonl", days_old=10)
    drop1 = _make_file("audit-2025-12-01.jsonl", days_old=200)
    drop2 = _make_file("access-2025-12-01.jsonl", days_old=200)
    other = _make_file("readme.txt", days_old=200)  # not audit/access — must keep

    audit.sweep_retention()

    assert os.path.exists(keep)
    assert not os.path.exists(drop1)
    assert not os.path.exists(drop2)
    assert os.path.exists(other)
```

- [ ] **Step 2: Implement retention + rotation in `audit.py`**

Append to `usermgmt/audit.py`:

```python
import glob
import subprocess


def sweep_retention() -> None:
    """Delete audit-*.jsonl and access-*.jsonl older than the configured window."""
    import time as _t

    cutoff = _t.time() - _cfg.audit_retention_days * 86400
    for pattern in ("audit-*.jsonl", "access-*.jsonl"):
        for path in glob.glob(os.path.join(_audit_dir(), pattern)):
            try:
                if os.path.getmtime(path) < cutoff:
                    os.unlink(path)
            except OSError as e:
                print(f"[audit] retention sweep failed for {path}: {e}", file=sys.stderr)


def rotate_nginx_access_log() -> None:
    """Rename access-current.jsonl → access-YYYY-MM-DD.jsonl (yesterday) and SIGUSR1 nginx."""
    current = os.path.join(_audit_dir(), "access-current.jsonl")
    if not os.path.exists(current):
        return
    yesterday = (
        datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=1)
    ).strftime("%Y-%m-%d")
    dated = os.path.join(_audit_dir(), f"access-{yesterday}.jsonl")
    try:
        os.replace(current, dated)
    except OSError as e:
        print(f"[audit] rotation rename failed: {e}", file=sys.stderr)
        return
    # Signal nginx to reopen log files
    try:
        subprocess.run(
            ["docker", "kill", "-s", "USR1", _cfg.auth_proxy_container],
            check=True, capture_output=True, timeout=5,
        )
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired) as e:
        print(f"[audit] nginx SIGUSR1 failed: {e}", file=sys.stderr)


def start_housekeeping_thread() -> None:
    """Run rotation at UTC 00:05 daily; retention sweep on boot + every 6h."""
    import time as _t

    def loop():
        sweep_retention()
        last_rotation_day = None
        while True:
            now = datetime.datetime.now(datetime.timezone.utc)
            # Rotate once a day around 00:05 UTC
            if now.hour == 0 and now.minute >= 5 and now.date() != last_rotation_day:
                rotate_nginx_access_log()
                last_rotation_day = now.date()
            # Sweep every 6h
            if now.minute == 0 and now.hour in (0, 6, 12, 18):
                sweep_retention()
            _t.sleep(45)

    t = threading.Thread(target=loop, name="audit-housekeeping", daemon=True)
    t.start()
```

Note: `subprocess` and `glob` imports go at the top of the file.

- [ ] **Step 3: Run tests**

```bash
python -m pytest tests/test_audit_retention.py -v
```

Expected: 1 passed.

- [ ] **Step 4: Start the thread on app boot**

In `app.py`'s `create_app`, after `audit.configure(cfg)`:

```python
audit.start_housekeeping_thread()
```

- [ ] **Step 5: Commit**

```bash
git add usermgmt/audit.py usermgmt/app.py usermgmt/tests/test_audit_retention.py
git commit -m "feat: daily nginx log rotation + 90-day retention sweep"
```

---

## Task 20: `/api/logs` endpoint + `/logs` page handler

**Files:**
- Modify: `usermgmt/audit.py` (add viewer endpoints)
- Modify: `usermgmt/app.py` (register the audit blueprint)
- Create: `usermgmt/tests/test_audit_viewer.py`

- [ ] **Step 1: Write failing tests**

`usermgmt/tests/test_audit_viewer.py`:

```python
import json
import os
import subprocess

import pytest


pytestmark = pytest.mark.integration


@pytest.fixture
def client(tmp_data_dir, monkeypatch):
    pw = os.environ["HTPASSWD_FILE"]
    subprocess.run(["htpasswd", "-bc", pw, "alice", "secret123"], check=True, capture_output=True)
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    with open(os.environ["USERS_FILE"], "w") as f:
        json.dump({"version": 1, "users": {"alice": {
            "role": "admin", "email": "a@b.c",
            "created_at": "n", "updated_at": "n"}}}, f)
    from app import create_app
    c = create_app().test_client()
    c.post("/auth/login", json={"username": "alice", "password": "secret123"})
    return c


def _seed_audit(today_rows, access_rows):
    import datetime
    today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    a_path = os.path.join(os.environ["AUDIT_DIR"], f"audit-{today}.jsonl")
    b_path = os.path.join(os.environ["AUDIT_DIR"], f"access-{today}.jsonl")
    with open(a_path, "w") as f:
        for r in today_rows:
            f.write(json.dumps(r) + "\n")
    with open(b_path, "w") as f:
        for r in access_rows:
            f.write(json.dumps(r) + "\n")
    return today


def test_viewer_merges_both_files(client):
    today = _seed_audit(
        today_rows=[{"ts": "2026-05-21T10:00:00.000Z", "actor": "alice",
                     "event": "login.success", "ip": "1.2.3.4"}],
        access_rows=[{"ts": "2026-05-21T10:00:05.000Z", "actor": "alice",
                      "event": "kong.api.request", "ip": "1.2.3.4",
                      "details": {"method": "GET", "path": "/services"}}],
    )
    r = client.get(f"/api/logs?date={today}")
    assert r.status_code == 200
    rows = r.json["rows"]
    assert len(rows) == 2
    # Sorted descending by ts
    assert rows[0]["event"] == "kong.api.request"
    assert rows[1]["event"] == "login.success"


def test_viewer_filters_by_actor(client):
    today = _seed_audit(
        today_rows=[
            {"ts": "T1", "actor": "alice", "event": "x"},
            {"ts": "T2", "actor": "bob", "event": "x"},
        ],
        access_rows=[],
    )
    r = client.get(f"/api/logs?date={today}&actor=alice")
    assert r.status_code == 200
    rows = r.json["rows"]
    assert len(rows) == 1
    assert rows[0]["actor"] == "alice"


def test_viewer_filters_by_event_glob(client):
    today = _seed_audit(
        today_rows=[
            {"ts": "T1", "actor": "alice", "event": "login.success"},
            {"ts": "T2", "actor": "alice", "event": "user.create"},
        ],
        access_rows=[],
    )
    r = client.get(f"/api/logs?date={today}&event=login.*")
    rows = r.json["rows"]
    assert len(rows) == 1


def test_viewer_admin_only(client):
    # Demote alice
    db_path = os.environ["USERS_FILE"]
    with open(db_path) as f:
        db = json.load(f)
    db["users"]["alice"]["role"] = "user"
    with open(db_path, "w") as f:
        json.dump(db, f)
    client.post("/auth/logout")
    client.post("/auth/login", json={"username": "alice", "password": "secret123"})

    r = client.get("/api/logs?date=2026-05-21")
    assert r.status_code == 403
```

- [ ] **Step 2: Implement viewer in `audit.py`**

Append to `usermgmt/audit.py`:

```python
import fnmatch

from flask import Blueprint, jsonify, request, send_from_directory


bp = Blueprint("audit", __name__)


def _read_jsonl(path: str):
    if not os.path.exists(path):
        return
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def _query(date: str, actor: str | None, event: str | None,
           limit: int, offset: int) -> dict:
    audit_path = os.path.join(_audit_dir(), f"audit-{date}.jsonl")
    access_today = os.path.join(_audit_dir(), "access-current.jsonl")
    access_dated = os.path.join(_audit_dir(), f"access-{date}.jsonl")

    today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    paths = [audit_path, access_dated if date != today else access_today]

    rows = []
    for p in paths:
        for r in _read_jsonl(p):
            r.setdefault("actor", "anonymous")
            if not r["actor"]:
                r["actor"] = "anonymous"
            if actor and r.get("actor") != actor:
                continue
            if event and not fnmatch.fnmatch(r.get("event", ""), event):
                continue
            rows.append(r)

    rows.sort(key=lambda r: r.get("ts", ""), reverse=True)
    total = len(rows)
    sliced = rows[offset: offset + limit]
    return {"rows": sliced, "total": total, "has_more": offset + limit < total}


import json as _json  # for top-of-file imports if not already there
```

Then add the routes:

```python
@bp.route("/api/logs")
def api_logs():
    from auth import require_admin, get_session_user  # noqa
    # Reuse the require_admin decorator
    @require_admin
    def inner():
        date = request.args.get("date") or datetime.datetime.now(
            datetime.timezone.utc
        ).strftime("%Y-%m-%d")
        actor = request.args.get("actor")
        event = request.args.get("event")
        limit = min(int(request.args.get("limit", "200")), 1000)
        offset = max(int(request.args.get("offset", "0")), 0)
        result = _query(date, actor, event, limit, offset)

        # Emit audit.view only when offset == 0 (first page of a search)
        if offset == 0:
            s = get_session_user() or {"u": "anonymous", "r": None}
            write("audit.view", actor=s["u"], actor_role=s["r"],
                  ip=request.remote_addr or "-",
                  details={"date": date, "actor": actor, "event": event})

        return jsonify(result)
    return inner()


@bp.route("/logs/")
def logs_page():
    from auth import require_admin
    @require_admin
    def inner():
        return send_from_directory("/app/static", "logs.html")
    return inner()
```

(Decorator-inside-function pattern keeps the blueprint registration order independent.)

- [ ] **Step 3: Register the blueprint in `app.py`**

```python
from audit import bp as audit_bp
app.register_blueprint(audit_bp)
```

- [ ] **Step 4: Run tests**

```bash
python -m pytest tests/test_audit_viewer.py -v
```

Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
git add usermgmt/audit.py usermgmt/app.py usermgmt/tests/test_audit_viewer.py
git commit -m "feat: /api/logs viewer with date/actor/event filters"
```

---

## Task 21: `logs.html` viewer page + `login.html` rebrand + two-step UI

**Files:**
- Create: `usermgmt/static/logs.html`
- Replace: `usermgmt/static/login.html`

This is the only step in PR 4 with no behavioural tests — it's pure UI. Smoke-test in a browser.

- [ ] **Step 1: Create `usermgmt/static/logs.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>SEHC AI Gateway — Audit Log</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; background:#0a1628; color:#cdd5e0; }
  header { padding: 16px 24px; background: rgba(0,52,89,0.95); display:flex; justify-content:space-between; }
  header h1 { font-size: 18px; margin:0; color:#fff; }
  header a { color:#00d09c; text-decoration:none; margin-left:16px; }
  .filters { padding: 16px 24px; display:flex; gap:12px; flex-wrap:wrap; background:rgba(255,255,255,0.02); }
  .filters input, .filters button { padding: 8px 12px; border-radius:8px; border:1px solid rgba(255,255,255,0.1); background:rgba(255,255,255,0.06); color:#fff; }
  .filters button { background:#00d09c; color:#003459; cursor:pointer; border:none; font-weight:700; }
  table { width:100%; border-collapse:collapse; }
  th, td { padding: 10px 14px; text-align:left; border-bottom:1px solid rgba(255,255,255,0.05); font-size:13px; }
  th { color:rgba(255,255,255,0.5); font-weight:600; text-transform:uppercase; letter-spacing:0.5px; }
  tr:hover { background:rgba(255,255,255,0.03); cursor:pointer; }
  pre { background:rgba(0,0,0,0.4); padding:14px; border-radius:8px; font-size:12px; white-space:pre-wrap; }
  .pager { padding: 16px 24px; display:flex; gap:8px; }
  .pager button { padding:6px 14px; border-radius:8px; border:1px solid rgba(255,255,255,0.1); background:transparent; color:#cdd5e0; cursor:pointer; }
  .pager button:disabled { opacity:0.4; cursor:not-allowed; }
</style>
</head>
<body>
<header>
  <h1>SEHC AI Gateway — Audit Log</h1>
  <div>
    <a href="/users/">Users</a>
    <a href="/">Kong Manager</a>
    <a href="/auth/logout">Logout</a>
  </div>
</header>
<div class="filters">
  <input id="date" type="date">
  <input id="actor" type="text" placeholder="actor (exact)">
  <input id="event" type="text" placeholder="event (glob: login.*)">
  <button onclick="load(0)">Search</button>
</div>
<table>
  <thead><tr><th>ts (UTC)</th><th>actor</th><th>role</th><th>ip</th><th>event</th><th>target</th></tr></thead>
  <tbody id="rows"></tbody>
</table>
<div class="pager">
  <button id="prev" onclick="load(offset - limit)">&lt; Newer</button>
  <span id="info" style="padding:6px"></span>
  <button id="next" onclick="load(offset + limit)">Older &gt;</button>
</div>
<pre id="detail" hidden></pre>

<script>
const limit = 200;
let offset = 0;
let total = 0;

document.getElementById('date').value = new Date().toISOString().slice(0, 10);

async function load(off) {
  offset = Math.max(0, off);
  const params = new URLSearchParams({
    date: document.getElementById('date').value,
    actor: document.getElementById('actor').value,
    event: document.getElementById('event').value,
    limit, offset,
  });
  // Drop empty params
  for (const k of [...params.keys()]) if (!params.get(k)) params.delete(k);
  const r = await fetch(`/api/logs?${params.toString()}`, { credentials: 'include' });
  if (!r.ok) {
    document.getElementById('rows').innerHTML = `<tr><td colspan=6>Error: ${r.status}</td></tr>`;
    return;
  }
  const data = await r.json();
  total = data.total;
  document.getElementById('rows').innerHTML = data.rows.map(row => `
    <tr onclick='showDetail(${JSON.stringify(JSON.stringify(row))})'>
      <td>${row.ts || ''}</td>
      <td>${row.actor || ''}</td>
      <td>${row.actor_role || ''}</td>
      <td>${row.ip || ''}</td>
      <td>${row.event || ''}</td>
      <td>${row.target || ''}</td>
    </tr>`).join('');
  document.getElementById('info').textContent = `${offset + 1}–${offset + data.rows.length} of ${total}`;
  document.getElementById('prev').disabled = offset === 0;
  document.getElementById('next').disabled = !data.has_more;
}

function showDetail(jsonStr) {
  const el = document.getElementById('detail');
  el.textContent = JSON.stringify(JSON.parse(jsonStr), null, 2);
  el.hidden = false;
}

load(0);
</script>
</body>
</html>
```

- [ ] **Step 2: Replace `usermgmt/static/login.html`**

Full file (the styles from the existing file are kept; the JS becomes a two-step state machine):

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>SEHC AI Gateway — Login</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background:#0a1628; min-height:100vh; display:flex; align-items:center; justify-content:center; overflow:hidden; }
  .bg-grid { position: fixed; inset:0; background-image:linear-gradient(rgba(0,212,156,0.04) 1px, transparent 1px), linear-gradient(90deg, rgba(0,212,156,0.04) 1px, transparent 1px); background-size:60px 60px; pointer-events:none; }
  .login-card { position:relative; background:rgba(255,255,255,0.03); border:1px solid rgba(255,255,255,0.08); border-radius:16px; padding:48px 40px 40px; width:400px; max-width:92%; backdrop-filter:blur(20px); box-shadow:0 24px 80px rgba(0,0,0,0.4); }
  .logo-row { display:flex; align-items:center; gap:14px; margin-bottom:32px; }
  .logo-icon { width:44px; height:44px; background:linear-gradient(135deg, #00d09c, #003459); border-radius:12px; display:flex; align-items:center; justify-content:center; font-weight:800; font-size:22px; color:white; box-shadow:0 4px 20px rgba(0,208,156,0.3); }
  .logo-text h1 { font-size:18px; font-weight:800; color:#fff; letter-spacing:0.5px; }
  .logo-text p { font-size:13px; color:rgba(255,255,255,0.4); margin-top:2px; }
  .form-group { margin-bottom:20px; }
  .form-group label { display:block; margin-bottom:7px; font-size:13px; font-weight:600; color:rgba(255,255,255,0.6); text-transform:uppercase; letter-spacing:0.5px; }
  .form-group input { width:100%; padding:12px 16px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:10px; color:#fff; font-size:15px; }
  .form-group input:focus { outline:none; border-color:#00d09c; box-shadow:0 0 0 3px rgba(0,208,156,0.15); }
  .btn { width:100%; padding:13px; background:linear-gradient(135deg,#00d09c,#00b386); border:none; border-radius:10px; color:#003459; font-size:15px; font-weight:700; cursor:pointer; box-shadow:0 4px 20px rgba(0,208,156,0.25); }
  .btn:disabled { opacity:0.6; cursor:not-allowed; }
  .alert { padding:11px 16px; border-radius:8px; margin-bottom:20px; font-size:14px; display:none; background:rgba(244,67,54,0.15); color:#ff6b6b; border:1px solid rgba(244,67,54,0.2); }
  .info { font-size:13px; color:rgba(255,255,255,0.6); margin-bottom:16px; }
  .link { background:none; border:none; color:#00d09c; cursor:pointer; padding:0; font-size:13px; text-decoration:underline; }
  .countdown { color:rgba(255,255,255,0.4); font-size:12px; margin-top:8px; text-align:center; }
</style>
</head>
<body>

<div class="bg-grid"></div>

<div class="login-card">
  <div class="logo-row">
    <div class="logo-icon">S</div>
    <div class="logo-text">
      <h1>SEHC AI GATEWAY</h1>
      <p>Admin Authentication</p>
    </div>
  </div>

  <div id="alert" class="alert"></div>

  <form id="password-form" onsubmit="doPassword(event)">
    <div class="form-group">
      <label>Username</label>
      <input type="text" id="username" required autocomplete="username" autofocus>
    </div>
    <div class="form-group">
      <label>Password</label>
      <input type="password" id="password" required autocomplete="current-password">
    </div>
    <button type="submit" class="btn" id="loginBtn">Sign In</button>
  </form>

  <form id="mfa-form" style="display:none" onsubmit="doCode(event)">
    <p class="info">A 6-digit code was sent to <span id="masked-email"></span>.</p>
    <div class="form-group">
      <label>Verification code</label>
      <input type="text" id="code" inputmode="numeric" pattern="[0-9]{6}" maxlength="6" required autocomplete="one-time-code" autofocus>
    </div>
    <button type="submit" class="btn" id="verifyBtn">Verify</button>
    <p class="countdown" id="countdown"></p>
    <p class="countdown">
      <button type="button" class="link" onclick="doResend()">Resend code</button>
      &nbsp;·&nbsp;
      <button type="button" class="link" onclick="backToPassword()">Back to login</button>
    </p>
  </form>
</div>

<script>
let challengeId = null;
let nextRedirect = null;
let countdownTimer = null;
let expiresAt = 0;

function showError(msg) {
  const el = document.getElementById('alert');
  el.textContent = msg;
  el.style.display = 'block';
  setTimeout(() => el.style.display = 'none', 4500);
}

function showStep(name) {
  document.getElementById('password-form').style.display = name === 'password' ? '' : 'none';
  document.getElementById('mfa-form').style.display = name === 'mfa' ? '' : 'none';
}

function startCountdown(expiresInSec) {
  expiresAt = Date.now() + expiresInSec * 1000;
  if (countdownTimer) clearInterval(countdownTimer);
  const el = document.getElementById('countdown');
  function tick() {
    const left = Math.max(0, Math.floor((expiresAt - Date.now()) / 1000));
    el.textContent = `Code expires in ${Math.floor(left / 60)}:${String(left % 60).padStart(2,'0')}`;
    if (left === 0) clearInterval(countdownTimer);
  }
  tick();
  countdownTimer = setInterval(tick, 1000);
}

async function doPassword(e) {
  e.preventDefault();
  const btn = document.getElementById('loginBtn');
  btn.disabled = true; btn.textContent = 'Signing in...';
  const username = document.getElementById('username').value.trim();
  const password = document.getElementById('password').value;
  try {
    const r = await fetch('/auth/login', {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({username, password}),
    });
    const data = await r.json();
    if (!r.ok) { showError(data.error || 'Login failed'); return; }
    if (data.step === 'mfa_required') {
      challengeId = data.challenge_id;
      document.getElementById('masked-email').textContent = data.masked_email;
      showStep('mfa');
      startCountdown(data.expires_in);
      document.getElementById('code').focus();
    } else if (data.step === 'ok') {
      goNext();
    }
  } catch (err) {
    showError('Connection error.');
  } finally {
    btn.disabled = false; btn.textContent = 'Sign In';
  }
}

async function doCode(e) {
  e.preventDefault();
  const btn = document.getElementById('verifyBtn');
  btn.disabled = true; btn.textContent = 'Verifying...';
  const code = document.getElementById('code').value.trim();
  try {
    const r = await fetch('/auth/mfa', {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({challenge_id: challengeId, code}),
    });
    const data = await r.json();
    if (!r.ok) {
      showError(data.error || 'Invalid code');
      if (r.status === 410) backToPassword();
      return;
    }
    goNext();
  } catch (err) {
    showError('Connection error.');
  } finally {
    btn.disabled = false; btn.textContent = 'Verify';
  }
}

async function doResend() {
  try {
    const r = await fetch('/auth/mfa/resend', {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({challenge_id: challengeId}),
    });
    const data = await r.json();
    if (!r.ok) { showError(data.error || 'Could not resend'); return; }
    showError('A new code has been sent.');  // re-uses the alert area as a success notice
    startCountdown(300);
  } catch (err) {
    showError('Connection error.');
  }
}

function backToPassword() {
  challengeId = null;
  if (countdownTimer) clearInterval(countdownTimer);
  document.getElementById('code').value = '';
  showStep('password');
  document.getElementById('username').focus();
}

function goNext() {
  const params = new URLSearchParams(window.location.search);
  const next = params.get('next') || '/';
  window.location.href = next;
}
</script>
</body>
</html>
```

- [ ] **Step 3: Smoke test in a browser**

```bash
docker compose up -d --build
```

Visit `http://192.168.1.121:8002/`. Expected: redirected to login. Title bar says "SEHC AI Gateway — Login". Logo shows "S". Sign in with the admin user. If `MFA_ENFORCED=false`, you land on Kong Manager. If `MFA_ENFORCED=true` and the user has an email, you see the MFA step.

- [ ] **Step 4: Commit**

```bash
git add usermgmt/static/logs.html usermgmt/static/login.html
git commit -m "feat: SEHC AI Gateway login rebrand + two-step UI + audit viewer page"
```

PR 4 is now complete. Open `feat: audit viewer, nginx logging, login rebrand`. After merge, follow the spec's rollout (Section 15): admins fill in emails, do a manual SMTP round-trip, then flip `MFA_ENFORCED=true` in `.env` and `docker compose up -d`.

---

# Self-Review Notes

I checked the plan against the spec. All 17 decisions (D1–D17), all 13 review-blocker fixes (atomic writes, HMAC, `X-Real-IP` only, CORS lockdown, `/data` mount, `mfa:true` claim, `SESSION_SECRET` fail-hard, audit-write resilience, JSON escaping, EmailMessage, migration backup, single-worker, blueprint split), and all rollout-flow requirements are covered. The pre-feature refactor list maps to T2–T7. The four PR boundaries align with Section 15 of the spec.

Methods used in later tasks match earlier definitions (`create_session_cookie(user, role, *, mfa)`, `_client_ip()`, `mfa.issue_challenge → (challenge_id, code)`, etc.). No "TBD" or "similar to" placeholders remain.

One trade-off worth flagging at execution time: T20 imports `require_admin` inside a closure to avoid blueprint-registration-order dependencies. If you prefer a cleaner pattern, refactor to register the audit blueprint after the auth blueprint and use `@require_admin` at the route definition — but the closure form ships working code.
