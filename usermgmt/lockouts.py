"""Persistent counters for password failures + MFA-code failures by IP."""

from __future__ import annotations

import os
import time

from storage import read_json_file, with_flock, write_json_file

_cfg = None


def configure(cfg) -> None:
    global _cfg
    _cfg = cfg


def _path() -> str:
    return _cfg.lockouts_file


def _lock() -> str:
    return _path() + ".lock"


def _empty() -> dict:
    return {"users": {}, "ips": {}}


def _load() -> dict:
    return read_json_file(_path(), default=_empty())


def _save(db: dict) -> None:
    write_json_file(_path(), db)


def _reset_for_tests() -> None:
    """Test helper — clears in-memory state (simulates process restart).

    The on-disk file is intentionally preserved so that the persistence test
    can verify that a fresh configure() picks up the previously written data.
    """
    global _cfg
    _cfg = None


def record_password_failure(username: str) -> None:
    with with_flock(_lock()):
        db = _load()
        rec = db["users"].setdefault(username, {"failed": 0, "locked_until": None})
        rec["failed"] += 1
        rec["last_fail_at"] = int(time.time())
        if rec["failed"] >= _cfg.pwd_lockout_threshold:
            rec["locked_until"] = int(time.time()) + _cfg.pwd_lockout_window_sec
        _save(db)


def is_user_locked(username: str) -> bool:
    db = _load()
    rec = db.get("users", {}).get(username)
    if not rec or not rec.get("locked_until"):
        return False
    if int(time.time()) >= rec["locked_until"]:
        # Window expired — clear in-place
        with with_flock(_lock()):
            db = _load()
            db.get("users", {}).pop(username, None)
            _save(db)
        return False
    return True


def clear_user(username: str) -> None:
    with with_flock(_lock()):
        db = _load()
        db.get("users", {}).pop(username, None)
        _save(db)


def record_mfa_failure(ip: str) -> None:
    with with_flock(_lock()):
        db = _load()
        rec = db["ips"].setdefault(ip, {"mfa_failed": 0, "locked_until": None})
        rec["mfa_failed"] += 1
        rec["last_fail_at"] = int(time.time())
        if rec["mfa_failed"] >= _cfg.ip_mfa_lockout_threshold:
            rec["locked_until"] = int(time.time()) + _cfg.ip_mfa_lockout_window_sec
        _save(db)


def is_ip_locked(ip: str) -> bool:
    db = _load()
    rec = db.get("ips", {}).get(ip)
    if not rec or not rec.get("locked_until"):
        return False
    if int(time.time()) >= rec["locked_until"]:
        with with_flock(_lock()):
            db = _load()
            db.get("ips", {}).pop(ip, None)
            _save(db)
        return False
    return True
