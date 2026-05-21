from unittest.mock import patch, MagicMock

import pytest

import mailer


pytestmark = pytest.mark.unit


@pytest.fixture(autouse=True)
def _config(tmp_data_dir, monkeypatch):
    monkeypatch.setenv("SMTP_HOST", "mail.internal")
    from config import Config

    cfg = Config.from_env()
    mailer.configure(cfg)
    return cfg


def test_send_code_uses_email_message():
    with patch("mailer.smtplib.SMTP") as smtp_cls:
        inst = MagicMock()
        smtp_cls.return_value.__enter__.return_value = inst

        mailer.send_mfa_code("alice@example.com", "alice", "123456")

        smtp_cls.assert_called_once_with("mail.internal", 587, timeout=10)
        inst.starttls.assert_called_once()
        inst.send_message.assert_called_once()
        msg = inst.send_message.call_args[0][0]
        assert "123456" in msg.get_content()
        assert msg["To"] == "alice@example.com"
        assert msg["Subject"].startswith("SEHC AI Gateway")


def test_send_code_optional_auth():
    with patch("mailer.smtplib.SMTP") as smtp_cls:
        inst = MagicMock()
        smtp_cls.return_value.__enter__.return_value = inst

        mailer.send_mfa_code("alice@example.com", "alice", "654321")

        # No username/pass set → no login call
        inst.login.assert_not_called()


def test_send_code_with_auth(monkeypatch):
    monkeypatch.setenv("SMTP_USER", "relay")
    monkeypatch.setenv("SMTP_PASS", "secret")
    from config import Config

    mailer.configure(Config.from_env())

    with patch("mailer.smtplib.SMTP") as smtp_cls:
        inst = MagicMock()
        smtp_cls.return_value.__enter__.return_value = inst

        mailer.send_mfa_code("alice@example.com", "alice", "111111")
        inst.login.assert_called_once_with("relay", "secret")


def test_send_code_raises_on_smtp_failure():
    with patch("mailer.smtplib.SMTP", side_effect=ConnectionRefusedError("no relay")):
        with pytest.raises(mailer.MailerError):
            mailer.send_mfa_code("alice@example.com", "alice", "000000")
