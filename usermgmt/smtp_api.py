"""Admin endpoints for SMTP overlay + test send."""

from __future__ import annotations

from flask import Blueprint, jsonify, request

bp = Blueprint("smtp_admin", __name__)


_CRLF_CHARS = ("\r", "\n", "\x00")


def _no_crlf(value: str) -> bool:
    """Reject CRLF / NUL — these are SMTP header-injection vectors."""
    return not any(c in value for c in _CRLF_CHARS)


@bp.route("/api/smtp", methods=["GET"])
def get_smtp():
    from auth import require_admin
    from smtp_settings import get_current, to_public_dict

    @require_admin
    def _inner():
        return jsonify(to_public_dict(get_current()))

    return _inner()


@bp.route("/api/smtp", methods=["PUT"])
def put_smtp():
    from auth import require_admin, get_session_user
    from smtp_settings import save_overlay
    import audit
    from utils import client_ip

    @require_admin
    def _inner():
        data = request.get_json(silent=True) or {}
        updates = {}

        if "host" in data:
            host = (data.get("host") or "").strip()
            if not host:
                return jsonify({"error": "host required"}), 400
            if not _no_crlf(host):
                return jsonify({"error": "host contains invalid characters"}), 400
            updates["host"] = host

        if "port" in data:
            try:
                p = int(data["port"])
            except (TypeError, ValueError):
                return jsonify({"error": "port must be an integer"}), 400
            if not (1 <= p <= 65535):
                return jsonify({"error": "port out of range"}), 400
            updates["port"] = p

        if "user" in data:
            user = (data.get("user") or "").strip()
            if not _no_crlf(user):
                return jsonify({"error": "user contains invalid characters"}), 400
            updates["user"] = user

        if "password" in data:
            pw = data["password"]
            if pw:
                if not _no_crlf(pw):
                    return jsonify({"error": "password contains invalid characters"}), 400
                updates["password"] = pw

        if "from_addr" in data:
            fa = (data.get("from_addr") or "").strip()
            if not fa:
                return jsonify({"error": "from_addr required"}), 400
            if not _no_crlf(fa):
                return jsonify({"error": "from_addr contains invalid characters"}), 400
            updates["from_addr"] = fa

        if "use_tls" in data:
            updates["use_tls"] = bool(data["use_tls"])

        if "timeout_sec" in data:
            try:
                t = int(data["timeout_sec"])
            except (TypeError, ValueError):
                return jsonify({"error": "timeout_sec must be integer"}), 400
            if not (1 <= t <= 120):
                return jsonify({"error": "timeout_sec out of range"}), 400
            updates["timeout_sec"] = t

        save_overlay(updates)
        s = get_session_user() or {"u": "anonymous", "r": None}
        details = {k: v for k, v in updates.items() if k != "password"}
        if "password" in updates:
            details["password_changed"] = True
        audit.write(
            "smtp.config.change",
            actor=s["u"], actor_role=s["r"],
            ip=client_ip(),
            details=details,
        )
        return jsonify({"message": "SMTP settings updated"})

    return _inner()


@bp.route("/api/smtp/test", methods=["POST"])
def test_smtp():
    from auth import require_admin, get_session_user
    from users import get_email
    from mailer import send_mfa_code, MailerError
    import audit
    from utils import client_ip

    @require_admin
    def _inner():
        s = get_session_user()
        if not s:
            return jsonify({"error": "Login required"}), 401
        email = get_email(s["u"])
        if not email:
            return jsonify({
                "error": "No email on file for your account. Set your email in the user list first.",
            }), 409

        try:
            send_mfa_code(email, s["u"], "TEST00")
        except MailerError as e:
            audit.write(
                "smtp.test.fail",
                actor=s["u"], actor_role=s["r"],
                ip=client_ip(),
                details={"reason": str(e)[:120]},
            )
            return jsonify({"error": f"Send failed: {e}"}), 503

        audit.write(
            "smtp.test.ok",
            actor=s["u"], actor_role=s["r"],
            ip=client_ip(),
            details={"to": email},
        )
        return jsonify({"message": f"Test email sent to {email}"})

    return _inner()
