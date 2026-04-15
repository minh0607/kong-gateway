import os
import hashlib
import hmac
import time
import json
import subprocess
from flask import Flask, request, jsonify, send_from_directory, Response, redirect, make_response

app = Flask(__name__)
HTPASSWD_FILE = os.environ.get("HTPASSWD_FILE", "/data/.htpasswd")
ROLES_FILE = os.environ.get("ROLES_FILE", "/data/roles.json")
SESSION_SECRET = os.environ.get("SESSION_SECRET", "kong-session-secret-change-me-2026")
SESSION_MAX_AGE = int(os.environ.get("SESSION_MAX_AGE", "1800"))  # 30 minutes


# ─── Role helpers ─────────────────────────────────────────────────────────────

def read_roles():
    if os.path.exists(ROLES_FILE):
        with open(ROLES_FILE, "r") as f:
            return json.load(f)
    return {}


def save_roles(roles):
    with open(ROLES_FILE, "w") as f:
        json.dump(roles, f, indent=2)


def get_role(username):
    roles = read_roles()
    return roles.get(username, "user")


def set_role(username, role):
    roles = read_roles()
    roles[username] = role
    save_roles(roles)


def remove_role(username):
    roles = read_roles()
    roles.pop(username, None)
    save_roles(roles)


def ensure_default_admin():
    """Ensure the first user in htpasswd has admin role if no admins exist."""
    roles = read_roles()
    if any(r == "admin" for r in roles.values()):
        return
    users = read_users()
    if users:
        roles[users[0]] = "admin"
        save_roles(roles)


# ─── Session helpers ──────────────────────────────────────────────────────────

def _sign(payload: str) -> str:
    return hmac.new(SESSION_SECRET.encode(), payload.encode(), hashlib.sha256).hexdigest()


def create_session_cookie(username: str) -> str:
    role = get_role(username)
    expires = int(time.time()) + SESSION_MAX_AGE
    payload = json.dumps({"u": username, "r": role, "e": expires}, separators=(",", ":"))
    sig = _sign(payload)
    return f"{payload}.{sig}"


def validate_session_cookie(cookie: str) -> dict | None:
    """Returns {"u": username, "r": role} or None."""
    if not cookie or "." not in cookie:
        return None
    try:
        payload, sig = cookie.rsplit(".", 1)
        if not hmac.compare_digest(sig, _sign(payload)):
            return None
        data = json.loads(payload)
        if data.get("e", 0) < int(time.time()):
            return None
        return {"u": data.get("u"), "r": data.get("r", "user")}
    except Exception:
        return None


# ─── htpasswd helpers ─────────────────────────────────────────────────────────

def read_users():
    users = []
    if os.path.exists(HTPASSWD_FILE):
        with open(HTPASSWD_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if line and ":" in line:
                    users.append(line.split(":")[0])
    return users


def read_entries():
    entries = []
    if os.path.exists(HTPASSWD_FILE):
        with open(HTPASSWD_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if line and ":" in line:
                    username, hashed = line.split(":", 1)
                    entries.append((username, hashed))
    return entries


def save_users(entries):
    with open(HTPASSWD_FILE, "w") as f:
        for username, hashed in entries:
            f.write(f"{username}:{hashed}\n")


def apr1_hash(password):
    result = subprocess.run(
        ["htpasswd", "-nb", "tmp", password],
        capture_output=True, text=True
    )
    return result.stdout.strip().split(":", 1)[1]


def verify_password(username, password):
    result = subprocess.run(
        ["htpasswd", "-vb", HTPASSWD_FILE, username, password],
        capture_output=True
    )
    return result.returncode == 0


# ─── Auth middleware ──────────────────────────────────────────────────────────

def get_session_user():
    cookie = request.cookies.get("kong_session")
    return validate_session_cookie(cookie)


def require_session(f):
    def decorated(*args, **kwargs):
        session = get_session_user()
        if not session:
            return redirect("/auth/login")
        return f(*args, **kwargs)
    decorated.__name__ = f.__name__
    return decorated


def require_admin(f):
    def decorated(*args, **kwargs):
        session = get_session_user()
        if not session:
            return jsonify({"error": "Login required"}), 401
        if session.get("r") != "admin":
            return jsonify({"error": "Admin access required"}), 403
        return f(*args, **kwargs)
    decorated.__name__ = f.__name__
    return decorated


# ─── Auth endpoints (for nginx auth_request + login/logout) ──────────────────

@app.route("/auth/check")
def auth_check():
    session = get_session_user()
    if session:
        resp = Response("OK", 200)
        resp.headers["X-Auth-User"] = session["u"]
        resp.headers["X-Auth-Role"] = session["r"]
        return resp
    return Response("Unauthorized", 401)


@app.route("/auth/login", methods=["GET"])
def login_page():
    return send_from_directory("/app/static", "login.html")


@app.route("/auth/login", methods=["POST"])
def login_submit():
    data = request.get_json(silent=True)
    if not data:
        return jsonify({"error": "Invalid request"}), 400

    username = data.get("username", "").strip()
    password = data.get("password", "").strip()

    if not username or not password:
        return jsonify({"error": "Username and password required"}), 400

    if not verify_password(username, password):
        return jsonify({"error": "Invalid username or password"}), 401

    ensure_default_admin()
    role = get_role(username)
    cookie_val = create_session_cookie(username)
    resp = jsonify({"message": "Login successful", "user": username, "role": role})
    resp.set_cookie(
        "kong_session", cookie_val,
        max_age=SESSION_MAX_AGE,
        httponly=True,
        samesite="Lax",
        path="/",
    )
    return resp


@app.route("/auth/logout", methods=["GET", "POST"])
def logout():
    resp = redirect("/auth/login")
    resp.delete_cookie("kong_session", path="/")
    return resp


# ─── User Management (admin-only) ────────────────────────────────────────────

@app.route("/")
@require_admin
def index():
    return send_from_directory("/app/static", "index.html")


@app.route("/api/users", methods=["GET"])
@require_admin
def list_users():
    roles = read_roles()
    users = [{"username": u, "role": roles.get(u, "user")} for u in read_users()]
    return jsonify({"users": users})


@app.route("/api/users", methods=["POST"])
@require_admin
def add_user():
    data = request.get_json()
    username = data.get("username", "").strip()
    password = data.get("password", "").strip()
    role = data.get("role", "user").strip()

    if role not in ("admin", "user"):
        return jsonify({"error": "Role must be 'admin' or 'user'"}), 400
    if not username or not password:
        return jsonify({"error": "Username and password required"}), 400
    if len(username) < 3:
        return jsonify({"error": "Username must be at least 3 characters"}), 400
    if len(password) < 6:
        return jsonify({"error": "Password must be at least 6 characters"}), 400

    entries = read_entries()
    for u, _ in entries:
        if u == username:
            return jsonify({"error": "User already exists"}), 409

    hashed = apr1_hash(password)
    entries.append((username, hashed))
    save_users(entries)
    set_role(username, role)
    return jsonify({"message": f"User '{username}' created as {role}"})


@app.route("/api/users/<username>", methods=["DELETE"])
@require_admin
def delete_user(username):
    entries = read_entries()
    new_entries = [(u, h) for u, h in entries if u != username]

    if len(new_entries) == len(entries):
        return jsonify({"error": "User not found"}), 404
    if len(new_entries) == 0:
        return jsonify({"error": "Cannot delete the last user"}), 400

    # Prevent deleting the last admin
    roles = read_roles()
    if roles.get(username) == "admin":
        admin_count = sum(1 for r in roles.values() if r == "admin")
        if admin_count <= 1:
            return jsonify({"error": "Cannot delete the last admin"}), 400

    save_users(new_entries)
    remove_role(username)
    return jsonify({"message": f"User '{username}' deleted"})


@app.route("/api/users/<username>/password", methods=["PUT"])
@require_admin
def change_password(username):
    data = request.get_json()
    password = data.get("password", "").strip()

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

    save_users(new_entries)
    return jsonify({"message": f"Password changed for '{username}'"})


@app.route("/api/users/<username>/role", methods=["PUT"])
@require_admin
def change_role(username):
    data = request.get_json()
    role = data.get("role", "").strip()

    if role not in ("admin", "user"):
        return jsonify({"error": "Role must be 'admin' or 'user'"}), 400

    if not any(u == username for u in read_users()):
        return jsonify({"error": "User not found"}), 404

    # Prevent removing the last admin
    if get_role(username) == "admin" and role == "user":
        roles = read_roles()
        admin_count = sum(1 for r in roles.values() if r == "admin")
        if admin_count <= 1:
            return jsonify({"error": "Cannot demote the last admin"}), 400

    set_role(username, role)
    return jsonify({"message": f"Role changed to '{role}' for '{username}'"})


@app.route("/api/session")
def session_info():
    session = get_session_user()
    if session:
        return jsonify({"authenticated": True, "user": session["u"], "role": session["r"]})
    return jsonify({"authenticated": False}), 401


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
