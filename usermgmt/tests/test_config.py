import pytest

from config import Config, LEGACY_DEFAULT_SECRET


pytestmark = pytest.mark.unit


def test_missing_secret_raises(monkeypatch):
    monkeypatch.delenv("SESSION_SECRET", raising=False)
    with pytest.raises(RuntimeError, match="SESSION_SECRET"):
        Config.from_env()


def test_legacy_default_secret_raises(monkeypatch):
    monkeypatch.setenv("SESSION_SECRET", LEGACY_DEFAULT_SECRET)
    with pytest.raises(RuntimeError, match="default"):
        Config.from_env()


def test_valid_config_loads(monkeypatch, tmp_data_dir):
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    cfg = Config.from_env()
    assert cfg.session_secret == "test-secret-not-the-default-value-xx"
    assert cfg.mfa_enforced is False  # default
    assert cfg.smtp_host == "mail.internal"
    assert cfg.smtp_port == 587
    assert cfg.audit_retention_days == 90


def test_mfa_enforced_true(monkeypatch, tmp_data_dir):
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    monkeypatch.setenv("MFA_ENFORCED", "true")
    cfg = Config.from_env()
    assert cfg.mfa_enforced is True
