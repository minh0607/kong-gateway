import json
import os
import shutil
import subprocess

import pytest


pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        shutil.which("htpasswd") is None,
        reason="htpasswd binary not found",
    ),
]


@pytest.fixture
def client(tmp_data_dir, monkeypatch):
    pw = os.environ["HTPASSWD_FILE"]
    subprocess.run(["htpasswd", "-bc", pw, "alice", "secret123"], check=True, capture_output=True)
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    from app import create_app
    return create_app().test_client()


def test_revoked_cookie_no_longer_valid(client):
    r = client.post("/auth/login", json={"username": "alice", "password": "secret123"})
    assert r.status_code == 200

    # Extract raw cookie value from Set-Cookie header
    set_cookie = r.headers.get("Set-Cookie", "")
    raw = set_cookie.split("kong_session=", 1)[1].split(";", 1)[0]

    # Before logout, /auth/check succeeds
    assert client.get("/auth/check").status_code == 200

    # Logout — server revokes the cookie
    client.post("/auth/logout")

    # Replay the old cookie value — should now be rejected
    client.set_cookie("kong_session", raw, domain="localhost")
    assert client.get("/auth/check").status_code == 401
