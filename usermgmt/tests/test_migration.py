import json
import os

import pytest

from users import migrate_legacy_roles_file


pytestmark = pytest.mark.unit


def test_migration_converts_roles_to_users_db(tmp_data_dir):
    roles_path = os.path.join(tmp_data_dir, "roles.json")
    users_path = os.environ["USERS_FILE"]
    with open(roles_path, "w") as f:
        json.dump({"alice": "admin", "bob": "user"}, f)

    migrate_legacy_roles_file(roles_path)

    with open(users_path) as f:
        db = json.load(f)
    assert db["version"] == 1
    assert db["users"]["alice"]["role"] == "admin"
    assert db["users"]["alice"]["email"] is None
    assert db["users"]["bob"]["role"] == "user"

    # Backup file present
    backups = [f for f in os.listdir(tmp_data_dir) if f.startswith("roles.json.bak-")]
    assert len(backups) == 1


def test_migration_idempotent(tmp_data_dir):
    roles_path = os.path.join(tmp_data_dir, "roles.json")
    with open(roles_path, "w") as f:
        json.dump({"alice": "admin"}, f)
    migrate_legacy_roles_file(roles_path)

    # Second migration should be a no-op (users.json already exists, roles.json was renamed)
    migrate_legacy_roles_file(roles_path)

    backups = [f for f in os.listdir(tmp_data_dir) if f.startswith("roles.json.bak-")]
    # Still exactly one backup
    assert len(backups) == 1


def test_migration_no_legacy_file_is_noop(tmp_data_dir):
    roles_path = os.path.join(tmp_data_dir, "roles.json")
    migrate_legacy_roles_file(roles_path)  # must not raise
    assert not os.path.exists(os.environ["USERS_FILE"])
