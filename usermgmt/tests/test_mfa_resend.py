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
    subprocess.run(["htpasswd", "-bc", pw_file, "alice", "secret123"],
                   check=True, capture_output=True)
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    monkeypatch.setenv("MFA_ENFORCED", "true")
    monkeypatch.setenv("MFA_RESEND_COOLDOWN_SEC", "0")
    with open(os.environ["USERS_FILE"], "w") as f:
        json.dump({"version": 1, "users": {"alice": {
            "role": "admin", "email": "alice@example.com",
            "created_at": "n", "updated_at": "n"}}}, f)
    from app import create_app
    return create_app().test_client()


def _start(client):
    codes = []
    def cap(to, user, code):
        codes.append(code)
    p = patch("mailer.send_mfa_code", side_effect=cap)
    p.start()
    r = client.post("/auth/login",
                    json={"username": "alice", "password": "secret123"},
                    headers={"X-Real-IP": "192.168.1.50"})
    return r.json["challenge_id"], codes, p


def test_resend_returns_new_code(client):
    chal, codes, p = _start(client)
    r = client.post("/auth/mfa/resend",
                    json={"challenge_id": chal},
                    headers={"X-Real-IP": "192.168.1.50"})
    p.stop()
    assert r.status_code == 200
    assert len(codes) == 2
    assert codes[0] != codes[1]


def test_resend_invalidates_old_code(client):
    chal, codes, p = _start(client)
    client.post("/auth/mfa/resend",
                json={"challenge_id": chal},
                headers={"X-Real-IP": "192.168.1.50"})
    # Old code should now be invalid
    r = client.post("/auth/mfa",
                    json={"challenge_id": chal, "code": codes[0]},
                    headers={"X-Real-IP": "192.168.1.50"})
    p.stop()
    assert r.status_code == 401


def test_resend_only_once(client):
    chal, _codes, p = _start(client)
    r1 = client.post("/auth/mfa/resend", json={"challenge_id": chal},
                     headers={"X-Real-IP": "192.168.1.50"})
    r2 = client.post("/auth/mfa/resend", json={"challenge_id": chal},
                     headers={"X-Real-IP": "192.168.1.50"})
    p.stop()
    assert r1.status_code == 200
    assert r2.status_code == 429
