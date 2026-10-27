"""Audit files are bucketed by the Vietnam (UTC+7) calendar day, not UTC.

Regression guard for the 00:00-07:00 VN window, where the old UTC bucketing put
"today" in the previous day's file. Entry timestamps stay UTC "Z".
"""

import datetime
import os

import pytest

import audit

pytestmark = pytest.mark.unit

_UTC = datetime.timezone.utc


@pytest.fixture(autouse=True)
def _cfg(tmp_data_dir, monkeypatch):
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    from config import Config

    cfg = Config.from_env()
    audit.configure(cfg)
    yield cfg


def test_vn_offset_is_plus_seven_no_dst():
    # Vietnam never observes DST, so the offset is a constant +7h.
    assert audit._VN_TZ.utcoffset(None) == datetime.timedelta(hours=7)


def test_evening_utc_belongs_to_next_vn_day():
    """18:30Z on 2026-10-25 is 01:30 on 2026-10-26 in Vietnam."""
    instant = datetime.datetime(2026, 10, 25, 18, 30, tzinfo=_UTC)

    vn_day = instant.astimezone(audit._VN_TZ).strftime("%Y-%m-%d")
    utc_day = instant.astimezone(_UTC).strftime("%Y-%m-%d")  # what the old code used

    assert vn_day == "2026-10-26"  # new: correct VN day
    assert utc_day == "2026-10-25"  # old behaviour would mis-bucket into the day before
    assert vn_day != utc_day


def test_write_buckets_into_vn_day_file(monkeypatch):
    """write() during the 00:00-07:00 VN window lands in the VN-day file, ts stays UTC Z."""
    # 01:30 on 2026-10-26 VN  == 18:30Z on 2026-10-25
    fixed_vn = datetime.datetime(2026, 10, 26, 1, 30, tzinfo=audit._VN_TZ)
    monkeypatch.setattr(audit, "_vn_now", lambda: fixed_vn)

    audit.write("test.event", actor="kong", details={"k": "v"})

    d = os.environ["AUDIT_DIR"]
    assert os.path.exists(os.path.join(d, "audit-2026-10-26.jsonl"))  # VN day
    assert not os.path.exists(os.path.join(d, "audit-2026-10-25.jsonl"))  # not the UTC day

    import json

    with open(os.path.join(d, "audit-2026-10-26.jsonl")) as f:
        row = json.loads(f.readline())
    assert row["event"] == "test.event"
    assert row["ts"].endswith("Z")  # entry timestamp remains UTC, unambiguous


def test_vn_today_helpers_use_offset(monkeypatch):
    fixed_vn = datetime.datetime(2026, 10, 26, 0, 10, tzinfo=audit._VN_TZ)
    monkeypatch.setattr(audit, "_vn_now", lambda: fixed_vn)
    assert audit._vn_today() == "2026-10-26"
    assert audit._today_path().endswith("audit-2026-10-26.jsonl")
