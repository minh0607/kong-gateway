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
