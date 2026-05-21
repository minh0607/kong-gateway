import os
import tempfile
import pytest


@pytest.fixture
def tmp_data_dir(monkeypatch):
    """Isolated /data tree per test."""
    with tempfile.TemporaryDirectory() as d:
        monkeypatch.setenv("HTPASSWD_FILE", os.path.join(d, ".htpasswd"))
        monkeypatch.setenv("USERS_FILE", os.path.join(d, "users.json"))
        monkeypatch.setenv("MFA_STATE_FILE", os.path.join(d, "mfa_state.json"))
        monkeypatch.setenv("LOCKOUTS_FILE", os.path.join(d, "lockouts.json"))
        monkeypatch.setenv("AUDIT_DIR", os.path.join(d, "audit"))
        os.makedirs(os.path.join(d, "audit"), exist_ok=True)
        monkeypatch.setenv("SESSION_SECRET", "test-secret-not-the-default-value-xx")
        yield d


@pytest.fixture
def session_secret(monkeypatch):
    monkeypatch.setenv("SESSION_SECRET", "test-secret-not-the-default-value-xx")
    yield "test-secret-not-the-default-value-xx"
