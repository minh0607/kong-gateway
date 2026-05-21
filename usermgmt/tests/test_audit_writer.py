import datetime
import json
import os

import pytest

import audit


pytestmark = pytest.mark.unit


@pytest.fixture(autouse=True)
def _config(tmp_data_dir, monkeypatch):
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    from config import Config

    cfg = Config.from_env()
    audit.configure(cfg)
    yield cfg


def test_write_appends_jsonl():
    audit.write("login.password.ok", actor="alice", ip="1.2.3.4")
    today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    path = os.path.join(os.environ["AUDIT_DIR"], f"audit-{today}.jsonl")
    with open(path) as f:
        rows = [json.loads(line) for line in f]
    assert len(rows) == 1
    assert rows[0]["event"] == "login.password.ok"
    assert rows[0]["actor"] == "alice"
    assert rows[0]["ip"] == "1.2.3.4"


def test_newline_in_actor_is_escaped():
    audit.write("user.create", actor="bob\nbad", ip="1.2.3.4", target="evil")
    today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    path = os.path.join(os.environ["AUDIT_DIR"], f"audit-{today}.jsonl")
    with open(path) as f:
        lines = f.readlines()
    assert len(lines) == 1
    row = json.loads(lines[0])
    assert row["actor"] == "bob\nbad"


def test_audit_healthy_flips_on_failure(monkeypatch):
    # Point AUDIT_DIR at an unwritable location
    monkeypatch.setattr(audit, "_audit_dir", lambda: "/nope/does/not/exist/forbidden")
    audit.write("startup", actor="system", ip="-")
    assert audit.healthy() is False
