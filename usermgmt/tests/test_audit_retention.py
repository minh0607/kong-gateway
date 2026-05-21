import datetime
import os

import pytest

import audit


pytestmark = pytest.mark.unit


@pytest.fixture(autouse=True)
def _cfg(tmp_data_dir, monkeypatch):
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    from config import Config

    cfg = Config.from_env()
    audit.configure(cfg)
    yield cfg


def _make_file(name, days_old):
    path = os.path.join(os.environ["AUDIT_DIR"], name)
    with open(path, "w") as f:
        f.write("{}\n")
    ts = datetime.datetime.now().timestamp() - days_old * 86400
    os.utime(path, (ts, ts))
    return path


def test_retention_deletes_old_files():
    keep = _make_file("audit-2026-05-20.jsonl", days_old=10)
    drop1 = _make_file("audit-2025-12-01.jsonl", days_old=200)
    drop2 = _make_file("access-2025-12-01.jsonl", days_old=200)
    other = _make_file("readme.txt", days_old=200)  # not audit/access — must keep

    audit.sweep_retention()

    assert os.path.exists(keep)
    assert not os.path.exists(drop1)
    assert not os.path.exists(drop2)
    assert os.path.exists(other)
