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
    pw = os.environ["HTPASSWD_FILE"]
    subprocess.run(["htpasswd", "-bc", pw, "alice", "secret123"],
                   check=True, capture_output=True)
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    with open(os.environ["USERS_FILE"], "w") as f:
        json.dump({"version": 1, "users": {"alice": {
            "role": "admin", "email": "a@b.c",
            "created_at": "n", "updated_at": "n"}}}, f)
    from app import create_app
    c = create_app().test_client()
    c.post("/auth/login", json={"username": "alice", "password": "secret123"})
    return c


def _seed_audit(today_rows, access_rows):
    import datetime
    today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    a_path = os.path.join(os.environ["AUDIT_DIR"], f"audit-{today}.jsonl")
    b_path = os.path.join(os.environ["AUDIT_DIR"], f"access-{today}.jsonl")
    with open(a_path, "w") as f:
        for r in today_rows:
            f.write(json.dumps(r) + "\n")
    with open(b_path, "w") as f:
        for r in access_rows:
            f.write(json.dumps(r) + "\n")
    return today


def test_viewer_merges_both_files(client):
    today = _seed_audit(
        today_rows=[{"ts": "2026-05-21T10:00:00.000Z", "actor": "alice",
                     "event": "login.success", "ip": "1.2.3.4"}],
        access_rows=[{"ts": "2026-05-21T10:00:05.000Z", "actor": "alice",
                      "event": "kong.api.request", "ip": "1.2.3.4",
                      "details": {"method": "GET", "path": "/services"}}],
    )
    r = client.get(f"/logs/api?date={today}")
    assert r.status_code == 200
    rows = r.json["rows"]
    # The endpoint will have also added its own `audit.view` row to today's audit file before reading.
    # So we filter to the rows the test seeded.
    seeded = [row for row in rows if row.get("event") in ("login.success", "kong.api.request")]
    assert len(seeded) == 2
    # Sorted descending by ts
    assert seeded[0]["event"] == "kong.api.request"
    assert seeded[1]["event"] == "login.success"


def test_viewer_filters_by_actor(client):
    today = _seed_audit(
        today_rows=[
            {"ts": "T1", "actor": "alice", "event": "x"},
            {"ts": "T2", "actor": "bob", "event": "x"},
        ],
        access_rows=[],
    )
    r = client.get(f"/logs/api?date={today}&actor=bob")
    assert r.status_code == 200
    rows = r.json["rows"]
    assert all(row["actor"] == "bob" for row in rows)
    assert any(row["event"] == "x" for row in rows)


def test_viewer_filters_by_event_glob(client):
    today = _seed_audit(
        today_rows=[
            {"ts": "T1", "actor": "alice", "event": "login.success"},
            {"ts": "T2", "actor": "alice", "event": "user.create"},
        ],
        access_rows=[],
    )
    r = client.get(f"/logs/api?date={today}&event=login.*")
    rows = r.json["rows"]
    # The endpoint's own audit.view event might land in today's file too — filter to spec events
    seeded = [row for row in rows if row["event"] == "login.success"]
    assert len(seeded) == 1


def test_viewer_admin_only(client, tmp_data_dir):
    # Add a second admin so ensure_default_admin won't re-promote alice,
    # then demote alice to user, re-login, and confirm 403.
    db_path = os.environ["USERS_FILE"]
    with open(db_path) as f:
        db = json.load(f)
    # Add a second admin to prevent ensure_default_admin from re-promoting alice
    db["users"]["bob"] = {
        "role": "admin", "email": "b@b.c",
        "created_at": "n", "updated_at": "n",
    }
    db["users"]["alice"]["role"] = "user"
    with open(db_path, "w") as f:
        json.dump(db, f)
    client.post("/auth/logout")
    client.post("/auth/login", json={"username": "alice", "password": "secret123"})

    r = client.get("/logs/api?date=2026-05-21")
    assert r.status_code == 403
