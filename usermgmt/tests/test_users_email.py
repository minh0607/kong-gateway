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
    assert r.status_code == 200, r.json


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


def test_change_mfa_requires_email(client):
    # Add a user with no email
    client.post("/api/users", json={
        "username": "noemail", "password": "secret789", "role": "user"
    })
    r = client.put("/api/users/noemail/mfa", json={"enabled": True})
    assert r.status_code == 400


def test_change_mfa_succeeds_with_email(client):
    client.post("/api/users", json={
        "username": "bob", "password": "secret789",
        "role": "user", "email": "bob@example.com"
    })
    r = client.put("/api/users/bob/mfa", json={"enabled": True})
    assert r.status_code == 200
    listing = client.get("/api/users").json["users"]
    bob = next(u for u in listing if u["username"] == "bob")
    assert bob["mfa_enabled"] is True


def test_disable_mfa_does_not_require_email(client):
    # Disable should always be allowed
    client.post("/api/users", json={
        "username": "bob", "password": "secret789",
        "role": "user", "email": "bob@example.com"
    })
    client.put("/api/users/bob/mfa", json={"enabled": True})
    # Disable regardless of email state
    r = client.put("/api/users/bob/mfa", json={"enabled": False})
    assert r.status_code == 200
