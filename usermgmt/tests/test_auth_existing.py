import os
import shutil
import subprocess

import pytest

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        shutil.which("htpasswd") is None,
        reason="htpasswd binary not found (install apache2-utils)",
    ),
]


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


def test_auth_check_admin_requires_session(client):
    r = client.get("/auth/check/admin")
    assert r.status_code == 401


def test_auth_check_admin_allows_admin(client):
    client.post("/auth/login", json={"username": "alice", "password": "secret123"})
    r = client.get("/auth/check/admin")
    assert r.status_code == 200
    assert r.headers.get("X-Auth-User") == "alice"
    assert r.headers.get("X-Auth-Role") == "admin"


def test_auth_check_admin_forbids_non_admin(client, app):
    # alice is the default admin; add a second, non-admin user.
    pw_file = os.environ["HTPASSWD_FILE"]
    subprocess.run(
        ["htpasswd", "-b", pw_file, "bob", "secret123"],
        check=True, capture_output=True,
    )
    from users import set_role
    with app.app_context():
        set_role("alice", "admin")  # keep an admin so bob is not auto-promoted
        set_role("bob", "user")

    client.post("/auth/login", json={"username": "bob", "password": "secret123"})
    r = client.get("/auth/check/admin")
    assert r.status_code == 403
