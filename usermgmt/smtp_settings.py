"""SMTP settings overlay: /data/smtp.json overrides env defaults.

The mailer calls get_current() per send, so changes are picked up
without a container restart.
"""

from __future__ import annotations

import os
from dataclasses import dataclass

from storage import read_json_file, with_flock, write_json_file

_cfg = None  # Config dataclass, set via configure()


def configure(cfg) -> None:
    global _cfg
    _cfg = cfg


def _path() -> str:
    return os.path.join(os.path.dirname(_cfg.users_file), "smtp.json")


def _lock() -> str:
    return _path() + ".lock"


@dataclass(frozen=True)
class SmtpSettings:
    host: str
    port: int
    user: str
    password: str
    from_addr: str
    use_tls: bool
    timeout_sec: int

    @property
    def pass_set(self) -> bool:
        return bool(self.password)


def _from_env() -> dict:
    return {
        "host": _cfg.smtp_host,
        "port": _cfg.smtp_port,
        "user": _cfg.smtp_user,
        "password": _cfg.smtp_pass,
        "from_addr": _cfg.smtp_from,
        "use_tls": _cfg.smtp_use_tls,
        "timeout_sec": _cfg.smtp_timeout_sec,
    }


def get_current() -> SmtpSettings:
    """Merge env defaults with overlay file (overlay wins)."""
    data = _from_env()
    overlay = read_json_file(_path(), default={})
    if isinstance(overlay, dict):
        for k in ("host", "port", "user", "password", "from_addr", "timeout_sec"):
            if k in overlay and overlay[k] is not None and overlay[k] != "":
                data[k] = overlay[k]
        # Booleans: must accept literal True/False in JSON
        if "use_tls" in overlay and isinstance(overlay["use_tls"], bool):
            data["use_tls"] = overlay["use_tls"]
    return SmtpSettings(**data)


def save_overlay(updates: dict) -> None:
    """Persist a partial overlay. Keys not present are not changed.

    If `password` is in `updates` and falsy (empty/None), the existing password
    in the overlay is preserved. If `password` is in `updates` and truthy,
    it replaces the existing one.
    """
    with with_flock(_lock()):
        existing = read_json_file(_path(), default={})
        if not isinstance(existing, dict):
            existing = {}
        for k in ("host", "port", "user", "from_addr", "use_tls", "timeout_sec"):
            if k in updates:
                existing[k] = updates[k]
        # Password handling: only overwrite when explicitly given and non-empty
        if updates.get("password"):
            existing["password"] = updates["password"]
        write_json_file(_path(), existing)


def to_public_dict(s: SmtpSettings) -> dict:
    """Render for the GUI — never includes the password."""
    return {
        "host": s.host,
        "port": s.port,
        "user": s.user,
        "from_addr": s.from_addr,
        "use_tls": s.use_tls,
        "timeout_sec": s.timeout_sec,
        "pass_set": s.pass_set,
    }
