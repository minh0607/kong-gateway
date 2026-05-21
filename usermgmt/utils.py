"""Shared request helpers."""

from __future__ import annotations

from flask import request


def client_ip() -> str:
    """Source IP from nginx-set X-Real-IP. Never trust X-Forwarded-For."""
    return request.headers.get("X-Real-IP") or (request.remote_addr or "-")
