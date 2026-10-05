#!/usr/bin/env python3
"""Apply ProtonX's small, reviewable changes to a pinned Proton Pass checkout."""
import pathlib
import subprocess
root = pathlib.Path(__file__).resolve().parent.parent
checkout = root / 'upstream/pass-cli'
subprocess.run(['git', 'apply', '--check', str(root / 'patches/pass-cli.patch')], cwd=checkout, check=True)
subprocess.run(['git', 'apply', str(root / 'patches/pass-cli.patch')], cwd=checkout, check=True)
