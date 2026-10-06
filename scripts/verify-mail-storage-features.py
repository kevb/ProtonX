#!/usr/bin/env python3
"""Check resolved production dependency features, not just manifest defaults."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
workspace = root / ".tools/mail-native"
base = ["cargo", "tree", "--locked", "-p", "protonx-mail-helper", "-e", "normal,build,features"]
normal = subprocess.check_output(base, cwd=workspace, text=True)
candidate = subprocess.check_output(base + ["--features", "secure-storage"], cwd=workspace, text=True)
assert 'protonx-mail-storage' in normal, "Normal helper must share the profile guard"
assert 'protonx-mail-storage feature "encryption"' not in normal, "Normal helper enabled encryption"
assert 'bundled-sqlcipher' not in normal, "Normal helper accidentally linked SQLCipher"
assert 'protonx-mail-storage feature "encryption"' in candidate, "Candidate omitted encryption engine"
assert 'bundled-sqlcipher-vendored-openssl' in candidate, "Candidate omitted SQLCipher"
print("Resolved Mail storage features verified: shared guard; encryption remains opt-in")
