import importlib
import json
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
def client_factory(tmp_data_dir, monkeypatch):
    pw = os.environ["HTPASSWD_FILE"]
    subprocess.run(["htpasswd", "-bc", pw, "alice", "secret123"],
                   check=True, capture_output=True)
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    with open(os.environ["USERS_FILE"], "w") as f:
        json.dump({"version": 1, "users": {"alice": {
            "role": "admin", "email": "a@b.c",
            "created_at": "n", "updated_at": "n"}}}, f)

    def make():
        import config
        import app as appmod
        importlib.reload(config)
        importlib.reload(appmod)
        return appmod.create_app().test_client()

    return make


def test_mfa_false_cookie_rejected_after_flag_flip(client_factory, monkeypatch):
    # First session: MFA disabled, cookie issued with mfa:false
    monkeypatch.setenv("MFA_ENFORCED", "false")
    c1 = client_factory()
    r = c1.post("/auth/login",
                json={"username": "alice", "password": "secret123"},
                headers={"X-Real-IP": "192.168.1.50"})
    assert r.status_code == 200, r.json
    cookie = r.headers.get("Set-Cookie", "")
    assert "kong_session=" in cookie
    # Extract just the cookie value
    raw = cookie.split("kong_session=", 1)[1].split(";", 1)[0]

    # Flip the flag, create a new app, send the old cookie
    monkeypatch.setenv("MFA_ENFORCED", "true")
    c2 = client_factory()
    c2.set_cookie("kong_session", raw, domain="localhost")
    r2 = c2.get("/auth/check")
    assert r2.status_code == 401
