import time

import pytest

import lockouts


pytestmark = pytest.mark.unit


@pytest.fixture(autouse=True)
def _configure(tmp_data_dir, monkeypatch):
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    from config import Config

    cfg = Config.from_env()
    lockouts.configure(cfg)
    yield cfg


def test_user_lockout_after_threshold():
    for _ in range(5):
        lockouts.record_password_failure("alice")
    assert lockouts.is_user_locked("alice")
    assert not lockouts.is_user_locked("bob")


def test_user_lockout_clears_on_success():
    for _ in range(3):
        lockouts.record_password_failure("alice")
    lockouts.clear_user("alice")
    assert not lockouts.is_user_locked("alice")


def test_user_lockout_expires_after_window(monkeypatch):
    for _ in range(5):
        lockouts.record_password_failure("alice")
    assert lockouts.is_user_locked("alice")
    # Fast-forward 16 minutes
    real_time = time.time
    monkeypatch.setattr(lockouts.time, "time", lambda: real_time() + 16 * 60)
    assert not lockouts.is_user_locked("alice")


def test_ip_mfa_lockout_after_threshold():
    for _ in range(10):
        lockouts.record_mfa_failure("192.168.1.50")
    assert lockouts.is_ip_locked("192.168.1.50")
    assert not lockouts.is_ip_locked("192.168.1.51")


def test_lockouts_persist_across_module_reload(_configure):
    for _ in range(5):
        lockouts.record_password_failure("alice")
    assert lockouts.is_user_locked("alice")
    # Simulate process restart by clearing in-memory state
    lockouts._reset_for_tests()
    lockouts.configure(_configure)
    assert lockouts.is_user_locked("alice")
