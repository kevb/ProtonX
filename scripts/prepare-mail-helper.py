#!/usr/bin/env python3
"""Materialize pinned public Mail source and the small native privacy/API patch.

No account/session data is accessed. All changes are in the ignored build tree.
"""
import json
import pathlib
import re
import shutil
import subprocess
import tomllib
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
source = next(s for s in json.loads((root / "upstream.lock.json").read_text())["sources"] if s["name"] == "clients")
upstream = root / "upstream/clients"
actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=upstream, text=True).strip()
if actual != source["revision"] or subprocess.check_output(["git", "status", "--porcelain"], cwd=upstream):
    raise SystemExit("Mail source differs from its clean pinned reference")
destination = root / ".tools/mail-native"
with tempfile.TemporaryDirectory(prefix="ProtonX-mail-source-") as stage:
    prepared = pathlib.Path(stage)
    for directory in ("project", "tools", "license"):
        shutil.copytree(upstream / directory, prepared / directory)
    manifest = (upstream / "Cargo.toml").read_text()
    members = [m for m in tomllib.loads(manifest)["workspace"]["members"] if (upstream / m / "Cargo.toml").is_file()]
    members.append("protonx-mail-helper")
    manifest = re.sub(r"members = \[.*?\]", "members = [\n" + "".join(f'    "{m}",\n' for m in members) + "]", manifest, count=1, flags=re.S)
    (prepared / "Cargo.toml").write_text(manifest)
    (prepared / ".cargo").mkdir()
    (prepared / ".cargo/config.toml").write_text('[net]\ngit-fetch-with-cli = true\n[registries.proton]\nindex = "sparse+https://rust-registry.proton.me/index/"\n')
    shutil.copy2(root / "Resources/MailHelper.lock", prepared / "Cargo.lock")
    shutil.copytree(root / "Tools/ProtonXMailHelper", prepared / "protonx-mail-helper")
    # A temporary directory outside the checkout avoids enclosing Git path filters.
    subprocess.run(["git", "apply", "--check", str(root / "patches/mail-core.patch")], cwd=prepared, check=True)
    subprocess.run(["git", "apply", str(root / "patches/mail-core.patch")], cwd=prepared, check=True)
    shutil.copy2(root / "Tools/MailContractTests/linked_sender.rs", prepared / "project/mail/rust/mail/mail-common/tests/protonx_linked_sender.rs")
    protocol = json.loads((root / "Resources/MailProtocol.json").read_text())
    constants = (
        f'pub const WEB_VERSION: &str = {json.dumps(protocol["webVersion"])};\n'
        f'pub const DESKTOP_VERSION: &str = {json.dumps(protocol["desktopVersion"])};\n'
        f'pub const USER_AGENT: &str = {json.dumps(protocol["userAgent"])};\n'
    )
    (prepared / "protonx-mail-helper/src/protocol.rs").write_text(constants)
    expected = {p.relative_to(prepared) for p in prepared.rglob("*") if p.is_file()}
    existing = {p.relative_to(destination) for p in destination.rglob("*") if p.is_file()}
    if existing - expected:
        raise SystemExit("Unexpected Mail build inputs; preserve/move the ignored source tree before retrying")
    for relative in sorted(expected):
        source_file, target = prepared / relative, destination / relative
        # Preserve unchanged mtimes: rebuilding a Swift view must not rebuild the SDK.
        if target.exists() and target.read_bytes() == source_file.read_bytes():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_file, target)
print(destination)
