#!/usr/bin/env python3
"""Exercise the compiled helper without any credential or network operation."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix="ProtonX-Calendar-Protocol-") as directory:
    requests = [
        {
            "schema": 1,
            "id": 1,
            "command": {
                "method": "snapshot",
                "start": 1791417600,
                "end": 1792022400,
                "zone": "UTC",
            },
        },
        {
            "schema": 1,
            "id": 2,
            "command": {"method": "create", "password": "synthetic-test-only"},
        },
    ]
    result = subprocess.run(
        [str(Path(sys.argv[1]).resolve())],
        input="".join(json.dumps(r) + "\n" for r in requests),
        text=True,
        capture_output=True,
        timeout=10,
        env={
            "PATH": "/usr/bin:/bin",
            "LANG": "en_US.UTF-8",
            "PROTONX_CALENDAR_DIR": directory,
        },
    )
    assert result.returncode == 0 and result.stderr == ""
    replies = [json.loads(line) for line in result.stdout.splitlines()]
    assert replies == [
        {"schema": 1, "id": 1, "failure": "operation_failed"},
        {"schema": 1, "id": 2, "failure": "invalid_input"},
    ]
    files = list(Path(directory).iterdir())
    assert len(files) == 1 and files[0].name == ".helper-lock"
    assert files[0].stat().st_mode & 0o777 == 0o600
print(
    "Compiled Calendar helper: private protocol, closed mutations and lock-only profile verified"
)
