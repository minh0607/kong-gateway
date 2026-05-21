"""Centralised env-variable parsing. Read once at startup."""

from __future__ import annotations

import os
from dataclasses import dataclass

LEGACY_DEFAULT_SECRET = "kong-session-secret-change-me-2026"


def _bool(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Config:
    htpasswd_file: str
    users_file: str
    mfa_state_file: str
    lockouts_file: str
    audit_dir: str
    session_secret: str
    session_max_age: int
    smtp_host: str
    smtp_port: int
    smtp_user: str
    smtp_pass: str
    smtp_from: str
    smtp_use_tls: bool
    smtp_timeout_sec: int
    mfa_enforced: bool
    mfa_code_ttl_sec: int
    mfa_max_attempts: int
    mfa_resend_cooldown_sec: int
    pwd_lockout_threshold: int
    pwd_lockout_window_sec: int
    ip_mfa_lockout_threshold: int
    ip_mfa_lockout_window_sec: int
    audit_retention_days: int
    auth_proxy_container: str

    @classmethod
    def from_env(cls) -> "Config":
        secret = os.environ.get("SESSION_SECRET")
        if not secret:
            raise RuntimeError("SESSION_SECRET env var is required")
        if secret == LEGACY_DEFAULT_SECRET:
            raise RuntimeError(
                "SESSION_SECRET is set to the legacy default — refuse to start"
            )
        smtp_host = os.environ.get("SMTP_HOST", "")
        return cls(
            htpasswd_file=os.environ.get("HTPASSWD_FILE", "/data/.htpasswd"),
            users_file=os.environ.get("USERS_FILE", "/data/users.json"),
            mfa_state_file=os.environ.get("MFA_STATE_FILE", "/data/mfa_state.json"),
            lockouts_file=os.environ.get("LOCKOUTS_FILE", "/data/lockouts.json"),
            audit_dir=os.environ.get("AUDIT_DIR", "/data/audit"),
            session_secret=secret,
            session_max_age=int(os.environ.get("SESSION_MAX_AGE", "1800")),
            smtp_host=smtp_host,
            smtp_port=int(os.environ.get("SMTP_PORT", "587")),
            smtp_user=os.environ.get("SMTP_USER", ""),
            smtp_pass=os.environ.get("SMTP_PASS", ""),
            smtp_from=os.environ.get(
                "SMTP_FROM", "SEHC AI Gateway <no-reply@sehc.local>"
            ),
            smtp_use_tls=_bool(os.environ.get("SMTP_USE_TLS", "true")),
            smtp_timeout_sec=int(os.environ.get("SMTP_TIMEOUT_SEC", "10")),
            mfa_enforced=_bool(os.environ.get("MFA_ENFORCED", "false")),
            mfa_code_ttl_sec=int(os.environ.get("MFA_CODE_TTL_SEC", "300")),
            mfa_max_attempts=int(os.environ.get("MFA_MAX_ATTEMPTS", "3")),
            mfa_resend_cooldown_sec=int(
                os.environ.get("MFA_RESEND_COOLDOWN_SEC", "60")
            ),
            pwd_lockout_threshold=int(os.environ.get("PWD_LOCKOUT_THRESHOLD", "5")),
            pwd_lockout_window_sec=int(
                os.environ.get("PWD_LOCKOUT_WINDOW_SEC", "900")
            ),
            ip_mfa_lockout_threshold=int(
                os.environ.get("IP_MFA_LOCKOUT_THRESHOLD", "10")
            ),
            ip_mfa_lockout_window_sec=int(
                os.environ.get("IP_MFA_LOCKOUT_WINDOW_SEC", "900")
            ),
            audit_retention_days=int(os.environ.get("AUDIT_RETENTION_DAYS", "90")),
            auth_proxy_container=os.environ.get(
                "AUTH_PROXY_CONTAINER", "kong-auth-proxy"
            ),
        )
