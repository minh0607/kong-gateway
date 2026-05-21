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

import audit

from flask import Blueprint, current_app, jsonify, redirect, request, send_from_directory, Response

bp = Blueprint("auth", __name__)


def _config():
    return current_app.config["CONFIG"]


def _sign(payload: str) -> str:
    secret = _config().session_secret.encode()
    return hmac.new(secret, payload.encode(), hashlib.sha256).hexdigest()


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


@bp.route("/auth/logout", methods=["GET", "POST"])
def logout():
    s = get_session_user()
    if s:
        audit.write("logout", actor=s["u"], actor_role=s["r"],
                    ip=request.remote_addr or "-")
    resp = redirect("/auth/login")
    resp.delete_cookie("kong_session", path="/")
    return resp


@bp.route("/api/session")
def session_info():
    s = get_session_user()
    if s:
        return jsonify({"authenticated": True, "user": s["u"], "role": s["r"]})
    return jsonify({"authenticated": False}), 401


@bp.route("/healthz")
def healthz():
    import audit as a
    return jsonify({"audit_healthy": a.healthy()}), (200 if a.healthy() else 503)
