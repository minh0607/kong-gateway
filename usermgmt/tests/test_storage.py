import json
import os
import threading

import pytest

from storage import read_json_file, write_json_file, with_flock


pytestmark = pytest.mark.unit


def test_read_returns_default_when_missing(tmp_data_dir):
    path = os.path.join(tmp_data_dir, "nope.json")
    assert read_json_file(path, default={"x": 1}) == {"x": 1}


def test_round_trip(tmp_data_dir):
    path = os.path.join(tmp_data_dir, "round.json")
    write_json_file(path, {"a": 1, "b": [2, 3]})
    assert read_json_file(path, default={}) == {"a": 1, "b": [2, 3]}


def test_atomic_write_leaves_no_partial_file_on_crash(tmp_data_dir, monkeypatch):
    path = os.path.join(tmp_data_dir, "atomic.json")
    write_json_file(path, {"good": True})
    # Force os.replace to fail; the temp file should be cleaned up,
    # and the original should be intact.
    import storage as s

    def boom(_src, _dst):
        raise OSError("simulated crash")

    monkeypatch.setattr(s.os, "replace", boom)
    with pytest.raises(OSError):
        write_json_file(path, {"bad": True})

    assert read_json_file(path, default=None) == {"good": True}
    # No stray tmp files left
    leftovers = [f for f in os.listdir(tmp_data_dir) if f.endswith(".tmp")]
    assert leftovers == []


def test_flock_serialises_threads(tmp_data_dir):
    path = os.path.join(tmp_data_dir, "lock.json")
    write_json_file(path, {"count": 0})
    lock_path = path + ".lock"

    def increment():
        with with_flock(lock_path):
            data = read_json_file(path, default={"count": 0})
            data["count"] += 1
            write_json_file(path, data)

    threads = [threading.Thread(target=increment) for _ in range(20)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert read_json_file(path, default={})["count"] == 20
