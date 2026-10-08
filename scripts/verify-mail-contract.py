#!/usr/bin/env python3
"""Verify Mail's independent desktop identity, public source and privacy patch."""
import json
import pathlib
import re
import subprocess
import tomllib

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
assert 'mod reader;' in helper
assert 'mod inbox_actions;' in helper
assert 'mod threads;' in helper
assert 'mod contacts;' in helper
assert (native / 'protonx-mail-helper/src/contacts.rs').read_bytes() == (root / 'Tools/ProtonXMailHelper/src/contacts.rs').read_bytes()
assert 'pub mod contacts;' in (native / 'project/mail/rust/mail/mail-uniffi/src/mail.rs').read_text()
assert (native / 'protonx-mail-helper/src/threads.rs').read_bytes() == (root / 'Tools/ProtonXMailHelper/src/threads.rs').read_bytes()
assert (native / 'protonx-mail-helper/src/inbox_actions.rs').read_bytes() == (root / 'Tools/ProtonXMailHelper/src/inbox_actions.rs').read_bytes()
assert (native / 'protonx-mail-helper/src/reader.rs').read_bytes() == (root / 'Tools/ProtonXMailHelper/src/reader.rs').read_bytes()
constants = (native / 'protonx-mail-helper/src/protocol.rs').read_text()
for key, name in [('webVersion', 'WEB_VERSION'), ('desktopVersion', 'DESKTOP_VERSION'), ('userAgent', 'USER_AGENT')]:
    assert f'pub const {name}: &str = {json.dumps(protocol[key])};' in constants
assert 'protonx-native' in (native / "protonx-mail-helper/Cargo.toml").read_text()
logging = (native / "project/mail/rust/mail/mail-uniffi/src/mail/logging.rs").read_text()
assert 'if cfg!(feature = "protonx-native")' in logging
telemetry = (native / "project/mail/rust/shared/telemetry-service/src/client.rs").read_text()
assert 'if cfg!(feature = "protonx-native")' in telemetry and 'return Ok(false);' in telemetry
draft_source = (native / "project/mail/rust/mail/mail-uniffi/src/mail/draft.rs").read_text()
assert 'auto_save_every: if cfg!(feature = "protonx-native") { None }' in draft_source
assert (native / "project/mail/rust/mail/mail-common/tests/protonx_linked_sender.rs").read_bytes() == (root / "Tools/MailContractTests/linked_sender.rs").read_bytes()
assert (native / "project/mail/rust/mail/mail-common/tests/protonx_local_storage.rs").read_bytes() == (root / "Tools/MailContractTests/local_storage.rs").read_bytes()
assert (native / "Cargo.lock").read_bytes() == (root / "Resources/MailHelper.lock").read_bytes()
for original in (root / "Tools/MailStorage").rglob("*"):
    if original.is_file():
        assert (native / "protonx-mail-storage" / original.relative_to(root / "Tools/MailStorage")).read_bytes() == original.read_bytes()
assert (native / "protonx-mail-helper/src/secure_storage.rs").read_bytes() == (root / "Tools/ProtonXMailHelper/src/secure_storage.rs").read_bytes()
assert (native / "project/mail/rust/mail/mail-common/tests/protonx_conversation_actions.rs").read_bytes() == (root / "Tools/MailContractTests/conversation_actions.rs").read_bytes()
pool = (native / "project/mail/rust/shared/stash/src/connection_manager.rs").read_text()
assert pool.index('protonx_mail_storage::initialize_sdk_connection(&c)?') < pool.index('(init_fn)(&mut c)?')
manifest = tomllib.loads((native / "protonx-mail-helper/Cargo.toml").read_text())
assert "secure-storage" not in manifest["features"].get("default", [])
main = helper.split("fn main()", 1)[1]
assert main.index('secure_storage::prepare(&directory)') < main.index('Backend::new(directory.clone())')
secure = (native / "protonx-mail-helper/src/secure_storage.rs").read_text()
assert secure.index('guard.check_startup(true)') < secure.index('get_generic_password(SERVICE, ACCOUNT)')
assert 'default-features = false' in (native / 'protonx-mail-helper/Cargo.toml').read_text()
assert main.index('guard.check_startup(false)') < main.index('Backend::new(directory.clone())')
assert main.index('drop(backend)') < main.index('std::process::exit(0)')
assert 'drop(storage_guard)' not in main
assert 'org.kevb.ProtonX.Mail.Storage' in secure

assert (native / "project/mail/rust/mail/mail-common/src/native_notifications.rs").read_bytes() == (root / "Tools/MailNotifications/native_notifications.rs").read_bytes()
for relative in ["messages.rs", "v6/event_subscriber.rs"]:
    assert "native_created.push(id)" in (native / "project/mail/rust/mail/mail-common/src/user_context/events" / relative).read_text()
assert "NotificationsPoll" in helper and "protonx_notifications(operation)" in helper

assert (native / "project/mail/rust/mail/mail-common/tests/protonx_notifications.rs").read_bytes() == (root / "Tools/MailContractTests/notifications.rs").read_bytes()

assert (native / "protonx-mail-helper/src/attachments.rs").read_bytes() == (root / "Tools/ProtonXMailHelper/src/attachments.rs").read_bytes()
assert (native / "project/mail/rust/mail/mail-common/tests/protonx_attachment_export.rs").read_bytes() == (root / "Tools/MailContractTests/attachment_export.rs").read_bytes()
assert "protonx_attachment_content" in (native / "project/mail/rust/mail/mail-uniffi/src/mail/mailbox/attachments.rs").read_text()
assert "cache_storage::read" in (native / "project/mail/rust/mail/mail-common/src/mailbox/attachments.rs").read_text()

handoff = (native / "project/mail/rust/mail/mail-uniffi/src/mail/user_session.rs").read_text()
assert (root / "Tools/MailAccountHandoff/sdk.rs").read_text() in handoff
assert 'fork("web", "calendar")' in handoff and "CalendarHandoff" in helper
assert "encode_handoff_key" not in helper

assert (root / "Tools/MailSearch/sdk.rs").read_text() in (native / "project/mail/rust/mail/mail-uniffi/src/mail/mail_scroller.rs").read_text()
assert (native / "protonx-mail-helper/src/search.rs").read_bytes() == (root / "Tools/ProtonXMailHelper/src/search.rs").read_bytes()

print("Independent native Mail protocol, privacy, notifications and account handoff contracts verified")
