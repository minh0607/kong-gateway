"""Endpoint-level tests for /api/smtp* — focuses on CRLF rejection."""

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
def client(tmp_data_dir, monkeypatch):
    pw_file = os.environ["HTPASSWD_FILE"]
    subprocess.run(
        ["htpasswd", "-bc", pw_file, "alice", "secret123"],
        check=True, capture_output=True,
    )
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    with open(os.environ["USERS_FILE"], "w") as f:
        json.dump({"version": 1, "users": {"alice": {
            "role": "admin", "email": "alice@example.com",
            "created_at": "n", "updated_at": "n"}}}, f)
    from app import create_app
    c = create_app().test_client()
    c.post("/auth/login", json={"username": "alice", "password": "secret123"})
    return c


@pytest.mark.parametrize("field", ["host", "user", "from_addr", "password"])
@pytest.mark.parametrize("injection", ["evil\nBcc: x", "a\rb", "x\x00y"])
def test_crlf_rejected(client, field, injection):
    payload = {field: injection if field != "from_addr" else "ok@example.com" + injection}
    # password=empty would be ignored; ensure non-empty
    if field == "password":
        payload = {"password": "good" + injection}
    r = client.put("/api/smtp", json=payload)
    assert r.status_code == 400, f"{field}={injection!r} should be rejected"


def test_clean_values_accepted(client):
    r = client.put("/api/smtp", json={
        "host": "mail.example.com",
        "port": 587,
        "user": "relay",
        "password": "secret",
        "from_addr": "SEHC <noreply@example.com>",
        "use_tls": True,
        "timeout_sec": 10,
    })
    assert r.status_code == 200
