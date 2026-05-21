"""Append-only JSONL audit writer with health flag."""

from __future__ import annotations

import datetime
import json
import os
import sys
import threading
from typing import Any, Optional

_cfg = None
_lock = threading.Lock()
_healthy = True


def configure(cfg) -> None:
    global _cfg, _healthy
    _cfg = cfg
    _healthy = True
    os.makedirs(_audit_dir(), exist_ok=True)


def _audit_dir() -> str:
    return _cfg.audit_dir


def _today_path() -> str:
    today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    return os.path.join(_audit_dir(), f"audit-{today}.jsonl")


def _now_iso_ms() -> str:
    now = datetime.datetime.now(datetime.timezone.utc)
    return now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"


def write(
    event: str,
    *,
    actor: str = "anonymous",
    actor_role: Optional[str] = None,
    ip: str = "-",
    target: Optional[str] = None,
    details: Optional[dict[str, Any]] = None,
) -> None:
    """Best-effort JSONL append. Failures flip the health flag but don't raise."""
    global _healthy
    row = {
        "ts": _now_iso_ms(),
        "actor": actor or "anonymous",
        "actor_role": actor_role,
        "ip": ip or "-",
        "event": event,
        "target": target,
        "details": details or {},
    }
    line = json.dumps(row, separators=(",", ":")) + "\n"
    try:
        with _lock:
            os.makedirs(_audit_dir(), exist_ok=True)
            with open(_today_path(), "a", encoding="utf-8") as f:
                f.write(line)
    except OSError as e:
        _healthy = False
        print(f"[audit] write failed: {e}", file=sys.stderr)


def healthy() -> bool:
    return _healthy
