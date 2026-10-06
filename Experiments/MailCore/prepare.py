#!/usr/bin/env python3
"""Prepare an isolated, credential-free build probe of Proton's public Mail SDK.

This does not patch the upstream checkout, build the app, or authenticate.
"""
import json
import pathlib
import re
import shutil
import subprocess
import tomllib

root = pathlib.Path(__file__).resolve().parents[2]
source = next(s for s in json.loads((root / "upstream.lock.json").read_text())["sources"]
              if s["name"] == "clients")
upstream = root / "upstream" / source["name"]
revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=upstream, text=True).strip()
if revision != source["revision"]:
    raise SystemExit("Mail reference revision differs from upstream.lock.json")
if subprocess.check_output(["git", "status", "--porcelain"], cwd=upstream):
    raise SystemExit("Preserve or restore upstream changes before preparing this probe")
destination = root / ".tools" / "mail-core-probe"
if destination.exists():
    raise SystemExit("Probe directory already exists; preserve its results before preparing another")

manifest = (upstream / "Cargo.toml").read_text()
workspace = tomllib.loads(manifest)["workspace"]
# The sanitized mirror omits unrelated workspace members. Keep only published
# members; dependencies of Mail must still resolve normally, without stubs.
members = [m for m in workspace["members"] if (upstream / m / "Cargo.toml").is_file()]
replacement = "members = [\n" + "".join(f'    "{m}",\n' for m in members) + "]"
manifest, count = re.subn(r"members = \[.*?\]", replacement, manifest, count=1, flags=re.S)
if count != 1:
    raise SystemExit("Upstream workspace layout changed")

destination.mkdir(parents=True)
for directory in ("project", "tools", "license"):
    shutil.copytree(upstream / directory, destination / directory)
shutil.copy2(pathlib.Path(__file__).with_name("Cargo.lock"), destination / "Cargo.lock")
shutil.copy2(upstream / "Cargo.lock", destination / "Cargo.upstream.lock")
(destination / "Cargo.toml").write_text(manifest)
(destination / ".cargo").mkdir()
# Public registries only. The published config routes crates.io through an
# internal Nexus host; no credentials or internal distribution are needed here.
(destination / ".cargo" / "config.toml").write_text(
    '[net]\ngit-fetch-with-cli = true\n'
    '[registries.proton]\nindex = "sparse+https://rust-registry.proton.me/index/"\n')
(destination / "PROTONX_PROBE.json").write_text(json.dumps({
    "revision": revision,
    "published_workspace_members": len(members),
    "omitted_workspace_members": len(workspace["members"]) - len(members),
    "production_dependency": False,
}, indent=2) + "\n")
print(destination)
