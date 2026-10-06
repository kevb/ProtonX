#!/usr/bin/env python3
"""Candidate startup refusal using only temporary synthetic legacy profiles.

Every case fails before Keychain access or SDK initialization. Never test an empty
profile here: that would request a real local Keychain storage key.
"""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

executable = str(Path(sys.argv[1]).resolve())
request = json.dumps({"schema": 1, "id": 1, "command": {"method": "restore"}}) + "\n"

def refused(root, expected):
    response = subprocess.run([executable], input=request.encode(), capture_output=True,
                              env={"PROTONX_MAIL_DIR": str(root)}, timeout=10)
    assert response.returncode == 0, "Candidate did not exit cleanly"
    # Closed failure only; never display helper stdout/stderr.
    reply = json.loads(response.stdout)
    assert reply == {"schema": 1, "id": 1, "failure": expected}, "Unexpected preflight result"
    assert not response.stderr, "Candidate emitted unexpected diagnostics"

with tempfile.TemporaryDirectory(prefix="ProtonX-synthetic-storage-") as directory:
    root = Path(directory)
    (root / "sessions").mkdir()
    database = root / "sessions/account.db"
    database.write_bytes(b"SQLite format 3\0SYNTHETIC-LEGACY-CONTENT")
    before = database.read_bytes()
    refused(root, "storage_upgrade_required")
    assert database.read_bytes() == before
    database.write_bytes(b"short")
    refused(root, "storage_unavailable")
    assert database.read_bytes() == b"short"
    database.unlink()
    target = root / "synthetic-target"
    target.write_bytes(before)
    database.symlink_to(target)
    refused(root, "storage_unavailable")
    assert database.is_symlink() and target.read_bytes() == before
    with (root / ".storage.lock").open("r+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        refused(root, "storage_unavailable")
print("4 synthetic helper preflight refusals passed; profiles retained")
