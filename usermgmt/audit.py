"""Append-only JSONL audit writer with health flag."""

from __future__ import annotations

import datetime
import json
import glob
import os
import subprocess
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


def sweep_retention() -> None:
    """Delete audit-*.jsonl and access-*.jsonl older than the configured window."""
    import time as _t

    cutoff = _t.time() - _cfg.audit_retention_days * 86400
    for pattern in ("audit-*.jsonl", "access-*.jsonl"):
        for path in glob.glob(os.path.join(_audit_dir(), pattern)):
            try:
                if os.path.getmtime(path) < cutoff:
                    os.unlink(path)
            except OSError as e:
                print(
                    f"[audit] retention sweep failed for {path}: {e}",
                    file=sys.stderr,
                )


def rotate_nginx_access_log() -> None:
    """Rename access-current.jsonl → access-YYYY-MM-DD.jsonl (yesterday) and SIGUSR1 nginx."""
    current = os.path.join(_audit_dir(), "access-current.jsonl")
    if not os.path.exists(current):
        return
    yesterday = (
        datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=1)
    ).strftime("%Y-%m-%d")
    dated = os.path.join(_audit_dir(), f"access-{yesterday}.jsonl")
    try:
        os.replace(current, dated)
    except OSError as e:
        print(f"[audit] rotation rename failed: {e}", file=sys.stderr)
        return
    try:
        subprocess.run(
            ["docker", "kill", "-s", "USR1", _cfg.auth_proxy_container],
            check=True, capture_output=True, timeout=5,
        )
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired) as e:
        print(f"[audit] nginx SIGUSR1 failed: {e}", file=sys.stderr)


def start_housekeeping_thread() -> None:
    """Run rotation at UTC 00:05 daily; retention sweep on boot + every 6h."""
    import time as _t

    def loop():
        sweep_retention()
        last_rotation_day = None
        while True:
            now = datetime.datetime.now(datetime.timezone.utc)
            # Rotate once a day around 00:05 UTC
            if now.hour == 0 and now.minute >= 5 and now.date() != last_rotation_day:
                rotate_nginx_access_log()
                last_rotation_day = now.date()
            # Sweep every 6h
            if now.minute == 0 and now.hour in (0, 6, 12, 18):
                sweep_retention()
            _t.sleep(45)

    t = threading.Thread(target=loop, name="audit-housekeeping", daemon=True)
    t.start()
