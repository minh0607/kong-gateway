"""Active MFA challenges. Persisted to mfa_state.json with flock + atomic write."""

from __future__ import annotations

import hashlib
import hmac
import secrets
import time

from storage import read_json_file, with_flock, write_json_file

_cfg = None


def configure(cfg) -> None:
    global _cfg
    _cfg = cfg


def _path() -> str:
    return _cfg.mfa_state_file


def _lock() -> str:
    return _path() + ".lock"


def _load() -> dict:
    return read_json_file(_path(), default={})


def _save(state: dict) -> None:
    write_json_file(_path(), state)


def _hmac(code: str) -> str:
    return hmac.new(
        _cfg.session_secret.encode(), code.encode(), hashlib.sha256
    ).hexdigest()


def _gc(state: dict) -> dict:
    now = int(time.time())
    return {cid: c for cid, c in state.items() if c.get("expires_at", 0) > now}


def issue_challenge(username: str, ip: str) -> tuple[str, str]:
    """Returns (challenge_id, code). Caller is responsible for emailing the code."""
    code = f"{secrets.randbelow(1_000_000):06d}"
    challenge_id = secrets.token_urlsafe(24)
    with with_flock(_lock()):
        state = _gc(_load())
        state[challenge_id] = {
            "username": username,
            "code_hmac": _hmac(code),
            "expires_at": int(time.time()) + _cfg.mfa_code_ttl_sec,
            "attempts_left": _cfg.mfa_max_attempts,
            "bound_ip": ip,
            "created_at": int(time.time()),
            "resends_left": 1,
            "last_sent_at": int(time.time()),
        }
        _save(state)
    return challenge_id, code


def get_challenge(challenge_id: str) -> dict | None:
    state = _gc(_load())
    return state.get(challenge_id)


def consume_challenge(challenge_id: str) -> None:
    with with_flock(_lock()):
        state = _load()
        state.pop(challenge_id, None)
        _save(state)


def fail_challenge(challenge_id: str) -> int:
    """Decrement attempts_left. Delete if zero. Returns remaining attempts."""
    with with_flock(_lock()):
        state = _load()
        rec = state.get(challenge_id)
        if not rec:
            return 0
        rec["attempts_left"] -= 1
        if rec["attempts_left"] <= 0:
            state.pop(challenge_id, None)
            _save(state)
            return 0
        _save(state)
        return rec["attempts_left"]


def verify_code(challenge_id: str, code: str) -> bool:
    rec = get_challenge(challenge_id)
    if not rec:
        return False
    return hmac.compare_digest(rec["code_hmac"], _hmac(code))


def reissue_code(challenge_id: str) -> str | None:
    """Resend path. Returns the new code, or None if not allowed."""
    with with_flock(_lock()):
        state = _load()
        rec = state.get(challenge_id)
        if not rec:
            return None
        now = int(time.time())
        if rec["resends_left"] <= 0:
            return None
        if now - rec["last_sent_at"] < _cfg.mfa_resend_cooldown_sec:
            return None
        new_code = f"{secrets.randbelow(1_000_000):06d}"
        rec["code_hmac"] = _hmac(new_code)
        rec["expires_at"] = now + _cfg.mfa_code_ttl_sec
        rec["attempts_left"] = _cfg.mfa_max_attempts
        rec["resends_left"] -= 1
        rec["last_sent_at"] = now
        _save(state)
        return new_code
