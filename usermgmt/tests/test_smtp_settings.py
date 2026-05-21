import json
import os

import pytest

import smtp_settings


pytestmark = pytest.mark.unit


@pytest.fixture(autouse=True)
def _configure(tmp_data_dir, monkeypatch):
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    from config import Config

    cfg = Config.from_env()
    smtp_settings.configure(cfg)
    yield cfg


def test_get_current_falls_back_to_env(_configure):
    s = smtp_settings.get_current()
    assert s.host == "mail.internal"
    assert s.port == 587


def test_overlay_overrides_env():
    smtp_settings.save_overlay({"host": "other.relay", "port": 25, "use_tls": False})
    s = smtp_settings.get_current()
    assert s.host == "other.relay"
    assert s.port == 25
    assert s.use_tls is False


def test_password_preserved_when_omitted():
    smtp_settings.save_overlay({"password": "secret1"})
    smtp_settings.save_overlay({"host": "x.relay"})  # no password key
    s = smtp_settings.get_current()
    assert s.password == "secret1"
    assert s.host == "x.relay"


def test_password_preserved_when_empty():
    smtp_settings.save_overlay({"password": "secret1"})
    smtp_settings.save_overlay({"password": "", "host": "y.relay"})  # empty == don't change
    s = smtp_settings.get_current()
    assert s.password == "secret1"
    assert s.host == "y.relay"


def test_password_replaced_when_non_empty():
    smtp_settings.save_overlay({"password": "secret1"})
    smtp_settings.save_overlay({"password": "secret2"})
    s = smtp_settings.get_current()
    assert s.password == "secret2"


def test_to_public_dict_excludes_password():
    smtp_settings.save_overlay({"password": "secret"})
    s = smtp_settings.get_current()
    pub = smtp_settings.to_public_dict(s)
    assert "password" not in pub
    assert pub["pass_set"] is True
