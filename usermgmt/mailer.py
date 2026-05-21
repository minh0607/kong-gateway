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
    import smtp_settings
    smtp_settings.configure(cfg)


_TEMPLATE = """Hello {username},

Your one-time verification code is:

    {code}

It expires in 5 minutes. If you didn't try to sign in, ignore this email
and contact your administrator.

— SEHC AI Gateway
"""


def send_mfa_code(to_email: str, username: str, code: str) -> None:
    from smtp_settings import get_current

    s = get_current()
    msg = EmailMessage()
    msg["From"] = s.from_addr
    msg["To"] = to_email
    msg["Subject"] = "SEHC AI Gateway — your verification code"
    msg.set_content(_TEMPLATE.format(username=username, code=code))
    try:
        with smtplib.SMTP(s.host, s.port, timeout=s.timeout_sec) as conn:
            if s.use_tls:
                conn.starttls()
            if s.user and s.password:
                conn.login(s.user, s.password)
            conn.send_message(msg)
    except (smtplib.SMTPException, OSError) as e:
        raise MailerError(str(e)) from e
