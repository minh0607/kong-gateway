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
