"""SMTP client for MFA codes. Uses EmailMessage to avoid header injection."""

from __future__ import annotations

import smtplib
from email.message import EmailMessage

_cfg = None


class MailerError(Exception):
    pass


def configure(cfg) -> None:
    global _cfg
    _cfg = cfg


_TEMPLATE = """Hello {username},

Your one-time verification code is:

    {code}

It expires in 5 minutes. If you didn't try to sign in, ignore this email
and contact your administrator.

— SEHC AI Gateway
"""


def send_mfa_code(to_email: str, username: str, code: str) -> None:
    msg = EmailMessage()
    msg["From"] = _cfg.smtp_from
    msg["To"] = to_email
    msg["Subject"] = "SEHC AI Gateway — your verification code"
    msg.set_content(_TEMPLATE.format(username=username, code=code))
    try:
        with smtplib.SMTP(_cfg.smtp_host, _cfg.smtp_port, timeout=_cfg.smtp_timeout_sec) as s:
            if _cfg.smtp_use_tls:
                s.starttls()
            if _cfg.smtp_user and _cfg.smtp_pass:
                s.login(_cfg.smtp_user, _cfg.smtp_pass)
            s.send_message(msg)
    except (smtplib.SMTPException, OSError) as e:
        raise MailerError(str(e)) from e
