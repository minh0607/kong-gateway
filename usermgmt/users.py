"""User management endpoints. Existing behaviour, blueprint form."""

from __future__ import annotations

import datetime
import json
import os
import re
import subprocess
import time as _time

import audit

from flask import Blueprint, current_app, jsonify, request, send_from_directory

from storage import read_json_file, with_flock, write_json_file

bp = Blueprint("users", __name__)


def _audit(event, target=None, details=None):
    """Log an audit event with the current session user as actor."""
    from auth import get_session_user

    s = get_session_user() or {"u": "anonymous", "r": None}
    audit.write(
        event,
        actor=s["u"],
        actor_role=s["r"],
        ip=request.remote_addr or "-",
        target=target,
        details=details,
    )


def _htpasswd_path() -> str:
    return current_app.config["CONFIG"].htpasswd_file


def _users_path() -> str:
    return current_app.config["CONFIG"].users_file


def _lock_path(path: str) -> str:
    return path + ".lock"


def _now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ─── htpasswd helpers ────────────────────────────────────────────


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


# ─── users.json (new DB shape) helpers ───────────────────────────


def _empty_db() -> dict:
    return {"version": 1, "users": {}}


def read_user_db() -> dict:
    return read_json_file(_users_path(), default=_empty_db())


def write_user_db(db: dict) -> None:
    with with_flock(_lock_path(_users_path())):
        write_json_file(_users_path(), db)


def get_role(username: str) -> str:
    rec = read_user_db().get("users", {}).get(username)
    return rec.get("role", "user") if rec else "user"


def set_role(username: str, role: str) -> None:
    db = read_user_db()
    rec = db["users"].setdefault(
        username,
        {"role": role, "email": None, "created_at": _now_iso(), "updated_at": _now_iso()},
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
        first,
        {"role": "admin", "email": None, "created_at": _now_iso(), "updated_at": _now_iso()},
    )
    db["users"][first]["role"] = "admin"
    write_user_db(db)


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
        username,
        {"role": "user", "email": None, "created_at": _now_iso(), "updated_at": _now_iso()},
    )
    rec["email"] = email
    rec["updated_at"] = _now_iso()
    write_user_db(db)


def get_email(username: str) -> str | None:
    return read_user_db().get("users", {}).get(username, {}).get("email")


def _resolve_users_path() -> str:
    try:
        return current_app.config["CONFIG"].users_file
    except RuntimeError:
        return os.environ.get("USERS_FILE", "/data/users.json")


def migrate_legacy_roles_file(roles_path: str) -> None:
    """One-shot migration from roles.json to users.json.

    Idempotent: if users.json already exists, this is a no-op even if a
    leftover roles.json is also present.
    """
    if not os.path.exists(roles_path):
        return
    users_path = _resolve_users_path()
    if os.path.exists(users_path):
        return

    with open(roles_path, "r", encoding="utf-8") as f:
        roles = json.load(f)
    now = _now_iso()
    db = {
        "version": 1,
        "users": {
            u: {
                "role": r,
                "email": None,
                "created_at": now,
                "updated_at": now,
            }
            for u, r in roles.items()
        },
    }
    write_json_file(users_path, db)
    backup = f"{roles_path}.bak-{int(_time.time())}"
    os.replace(roles_path, backup)


# ─── Endpoints ───────────────────────────────────────────────────


@bp.route("/", endpoint="index")
def index():
    from auth import require_admin

    @require_admin
    def _inner():
        return send_from_directory("/app/static", "index.html")

    return _inner()


@bp.route("/api/users", methods=["GET"])
def list_users():
    from auth import require_admin

    @require_admin
    def _inner():
        db = read_user_db()
        users = []
        for u in read_users():
            rec = db.get("users", {}).get(u, {})
            users.append({
                "username": u,
                "role": rec.get("role", "user"),
                "email": rec.get("email"),
            })
        return jsonify({"users": users})

    return _inner()


@bp.route("/api/users", methods=["POST"])
def add_user():
    from auth import require_admin

    @require_admin
    def _inner():
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

        email = (data.get("email") or "").strip()
        if email and not _valid_email(email):
            return jsonify({"error": "Invalid email"}), 400

        entries = read_entries()
        if any(u == username for u, _ in entries):
            return jsonify({"error": "User already exists"}), 409

        entries.append((username, apr1_hash(password)))
        save_entries(entries)
        set_role(username, role)
        if email:
            _set_email(username, email)
        _audit("user.create", target=username, details={"role": role})
        return jsonify({"message": f"User '{username}' created as {role}"})

    return _inner()


@bp.route("/api/users/<username>", methods=["DELETE"])
def delete_user(username):
    from auth import require_admin

    @require_admin
    def _inner():
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
        _audit("user.delete", target=username)
        return jsonify({"message": f"User '{username}' deleted"})

    return _inner()


@bp.route("/api/users/<username>/password", methods=["PUT"])
def change_password(username):
    from auth import require_admin

    @require_admin
    def _inner():
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
        _audit("user.password.change", target=username)
        return jsonify({"message": f"Password changed for '{username}'"})

    return _inner()


@bp.route("/api/users/<username>/role", methods=["PUT"])
def change_role(username):
    from auth import require_admin

    @require_admin
    def _inner():
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
        _audit("user.role.change", target=username, details={"role": role})
        return jsonify({"message": f"Role changed to '{role}' for '{username}'"})

    return _inner()


@bp.route("/api/users/<username>/email", methods=["PUT"])
def change_email(username):
    from auth import require_admin

    @require_admin
    def _inner():
        data = request.get_json() or {}
        email = (data.get("email") or "").strip()
        if not _valid_email(email):
            return jsonify({"error": "Invalid email"}), 400

        # User must exist in either the htpasswd file or the users.json DB
        db = read_user_db()
        if username not in db.get("users", {}) and username not in read_users():
            return jsonify({"error": "User not found"}), 404

        _set_email(username, email)
        _audit("user.email.change", target=username)
        return jsonify({"message": f"Email updated for '{username}'"})

    return _inner()
