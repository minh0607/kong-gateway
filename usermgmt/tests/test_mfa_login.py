import importlib
import json
import os
import shutil
import subprocess
from unittest.mock import patch

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
    monkeypatch.setenv("MFA_ENFORCED", "true")
    with open(os.environ["USERS_FILE"], "w") as f:
        json.dump({"version": 1, "users": {"alice": {
            "role": "admin", "email": "alice@example.com",
            "created_at": "now", "updated_at": "now"}}}, f)
    from app import create_app
    return create_app().test_client()


def test_login_step1_returns_challenge(client):
    with patch("mailer.send_mfa_code") as send:
        r = client.post("/auth/login",
                        json={"username": "alice", "password": "secret123"},
                        headers={"X-Real-IP": "192.168.1.50"})
    assert r.status_code == 200, r.json
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


@pytest.fixture
def client_factory(tmp_data_dir, monkeypatch):
    pw = os.environ["HTPASSWD_FILE"]
    subprocess.run(["htpasswd", "-bc", pw, "alice", "secret123"],
                   check=True, capture_output=True)
    monkeypatch.setenv("SMTP_HOST", "mail.internal")

    def make():
        import config
        import app as appmod
        importlib.reload(config)
        importlib.reload(appmod)
        return appmod.create_app().test_client()

    return make


def test_per_user_mfa_triggers_challenge_when_global_off(client_factory, monkeypatch):
    monkeypatch.setenv("MFA_ENFORCED", "false")
    with open(os.environ["USERS_FILE"], "w") as f:
        json.dump({"version": 1, "users": {"alice": {
            "role": "admin", "email": "alice@example.com",
            "mfa_enabled": True,
            "created_at": "n", "updated_at": "n"}}}, f)
    c = client_factory()

    with patch("mailer.send_mfa_code") as send:
        r = c.post("/auth/login",
                   json={"username": "alice", "password": "secret123"},
                   headers={"X-Real-IP": "192.168.1.50"})
    assert r.status_code == 200
    assert r.json["step"] == "mfa_required"
    assert send.called
