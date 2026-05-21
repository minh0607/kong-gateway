"""Atomic JSON storage with file locking.

Every write goes through `write_json_file`, which writes a temp file
then `os.replace`s it onto the final path. Read-modify-write cycles
use `with_flock` to serialise concurrent threads.
"""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
import tempfile
from typing import Any, Iterator


def read_json_file(path: str, default: Any) -> Any:
    if not os.path.exists(path):
        return default
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def write_json_file(path: str, data: Any) -> None:
    dir_ = os.path.dirname(path) or "."
    os.makedirs(dir_, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=dir_, suffix=".tmp")
    f = None
    try:
        f = os.fdopen(fd, "w", encoding="utf-8")
        json.dump(data, f, indent=2, sort_keys=True)
        f.flush()
        os.fsync(f.fileno())
        f.close()
        f = None
        os.replace(tmp, path)
    except Exception:
        if f is not None:
            # os.fdopen succeeded — close via the file object.
            with contextlib.suppress(Exception):
                f.close()
        else:
            # os.fdopen itself raised — close the raw fd directly.
            with contextlib.suppress(OSError):
                os.close(fd)
        # Best-effort cleanup; ignore secondary failures.
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


@contextlib.contextmanager
def with_flock(lock_path: str) -> Iterator[None]:
    """Acquire an exclusive advisory lock on a sibling .lock file."""
    os.makedirs(os.path.dirname(lock_path) or ".", exist_ok=True)
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
