"""Append-only JSONL audit writer with health flag."""

from __future__ import annotations

import datetime
import fnmatch
import json
import glob
import os
import subprocess
import sys
import threading
from typing import Any, Optional

from flask import Blueprint, jsonify, request, send_from_directory
from utils import client_ip

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


bp = Blueprint("audit", __name__)


def _read_jsonl(path: str):
    if not os.path.exists(path):
        return
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def _query(date: str, actor: str | None, event: str | None,
           limit: int, offset: int) -> dict:
    audit_path = os.path.join(_audit_dir(), f"audit-{date}.jsonl")
    access_today = os.path.join(_audit_dir(), "access-current.jsonl")
    access_dated = os.path.join(_audit_dir(), f"access-{date}.jsonl")

    today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    if date == today:
        paths = [audit_path, access_today, access_dated]
    else:
        paths = [audit_path, access_dated]

    rows = []
    for p in paths:
        for r in _read_jsonl(p):
            r.setdefault("actor", "anonymous")
            if not r["actor"]:
                r["actor"] = "anonymous"
            if actor and r.get("actor") != actor:
                continue
            if event and not fnmatch.fnmatch(r.get("event", ""), event):
                continue
            rows.append(r)

    rows.sort(key=lambda r: r.get("ts", ""), reverse=True)
    total = len(rows)
    sliced = rows[offset: offset + limit]
    return {"rows": sliced, "total": total, "has_more": offset + limit < total}


@bp.route("/logs/api")
def api_logs():
    from auth import get_session_user, require_admin

    @require_admin
    def inner():
        date = request.args.get("date") or datetime.datetime.now(
            datetime.timezone.utc
        ).strftime("%Y-%m-%d")
        actor = request.args.get("actor")
        event = request.args.get("event")
        limit = min(int(request.args.get("limit", "200")), 1000)
        offset = max(int(request.args.get("offset", "0")), 0)
        result = _query(date, actor, event, limit, offset)

        # Emit audit.view ONLY on the first page of a search
        if offset == 0:
            s = get_session_user() or {"u": "anonymous", "r": None}
            write("audit.view", actor=s["u"], actor_role=s["r"],
                  ip=client_ip(),
                  details={"date": date, "actor": actor, "event": event})

        return jsonify(result)

    return inner()


@bp.route("/logs/")
def logs_page():
    from auth import require_admin

    @require_admin
    def inner():
        return send_from_directory("/app/static", "logs.html")

    return inner()
