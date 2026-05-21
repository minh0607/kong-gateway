"""Flask factory for kong-usermgmt."""

from __future__ import annotations

import os

from flask import Flask

from config import Config


def create_app() -> Flask:
    app = Flask(__name__)
    cfg = Config.from_env()
    app.config["CONFIG"] = cfg

    import os.path
    from users import migrate_legacy_roles_file

    roles_legacy = os.path.join(os.path.dirname(cfg.users_file), "roles.json")
    migrate_legacy_roles_file(roles_legacy)

    from auth import bp as auth_bp
    from users import bp as users_bp

    app.register_blueprint(auth_bp)
    app.register_blueprint(users_bp)

    return app


if os.environ.get("SESSION_SECRET"):
    app = create_app()


if __name__ == "__main__":
    # Development entrypoint only — production runs gunicorn.
    app.run(host="0.0.0.0", port=5000)
