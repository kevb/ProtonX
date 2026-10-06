#!/usr/bin/env python3
"""Verify Mail's independent desktop identity, public source and privacy patch."""
import json
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
protocol = json.loads((root / "Resources/MailProtocol.json").read_text())
pins = json.loads((root / "upstream.lock.json").read_text())["sources"]
desktop = next(p for p in pins if p["name"] == "WebClients")
assert protocol["schema"] == 1 and protocol["desktopRevision"] == desktop["revision"]
def read(path):
    return subprocess.check_output(["git", "show", desktop["revision"] + ":" + path], cwd=root / "upstream/WebClients", text=True)
constants = read("packages/shared/lib/constants.ts").split("[APPS.PROTONMAIL]: {", 1)[1].split("},", 1)[0]
assert protocol["clientID"] == re.search(r"macosClientID: '([^']+)'", constants).group(1)
assert protocol["desktopVersion"] == json.loads(read("applications/inbox-desktop/package.json"))["version"]
assert '+id${app.getVersion()}' in read("applications/inbox-desktop/src/utils/session.ts")
assert re.fullmatch(r"\d+\.\d+\.\d+\.\d+", protocol["webVersion"])
assert re.fullmatch(r"[0-9a-f]{64}", protocol["webAssetSHA256"])
assert protocol["userAgent"].startswith("ProtonX/")
native = root / ".tools/mail-native"
helper = (native / "protonx-mail-helper/src/main.rs").read_text()
assert 'platform: "macos"' in helper and 'product: "mail"' in helper
assert re.search(r'protocol::WEB_VERSION,\s*protocol::DESKTOP_VERSION', helper)
assert 'mod protocol;' in helper
constants = (native / 'protonx-mail-helper/src/protocol.rs').read_text()
for key, name in [('webVersion', 'WEB_VERSION'), ('desktopVersion', 'DESKTOP_VERSION'), ('userAgent', 'USER_AGENT')]:
    assert f'pub const {name}: &str = {json.dumps(protocol[key])};' in constants
assert 'protonx-native' in (native / "protonx-mail-helper/Cargo.toml").read_text()
logging = (native / "project/mail/rust/mail/mail-uniffi/src/mail/logging.rs").read_text()
assert 'if cfg!(feature = "protonx-native")' in logging
telemetry = (native / "project/mail/rust/shared/telemetry-service/src/client.rs").read_text()
assert 'if cfg!(feature = "protonx-native")' in telemetry and 'return Ok(false);' in telemetry
assert (native / "Cargo.lock").read_bytes() == (root / "Resources/MailHelper.lock").read_bytes()
print("Independent native Mail protocol and privacy contracts verified")
