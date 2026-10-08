# Third-party notices

ProtonX is free software under GPL-3.0-or-later, with no warranty. See `LICENSE`.
ProtonX is independent of Proton AG. Proton, Proton Mail, and Proton Pass are
trademarks of their respective owners. No Proton logo or official application
branding is redistributed.

## Proton Pass helper (redistributed in locally built app bundles)

Copyright (c) 2026 Proton AG. GPL-3.0-or-later.
Source: https://github.com/protonpass/pass-cli
Revision: see `upstream.lock.json`. Changes: `patches/pass-cli.patch`.
The helper retains the original encryption, sync, server product checks,
and macOS Keychain implementation. The patch adds private native credential
prompts, stdin field updates, a separate Keychain namespace, safe failure
categories/numeric codes, an explicit desktop protocol policy, a parameterized
desktop account-fork target, a restricted desktop command surface, and suppresses
upstream update checks in native mode. The original CLI policy retains CLI
eligibility; the native desktop build follows the desktop product protocol. Dependency resolutions are pinned in
`Resources/PassHelper.lock`. The helper also includes Proton Pass Common,
Proton crypto/account libraries, Muon, and other Rust dependencies. Their
original licenses and notices must accompany any binary distribution.

The build uses macOS system frameworks and Apple's system libcurl. See Apple's
system third-party notices for those components; they are not bundled by ProtonX.

## Native Mail helper (redistributed in locally built app bundles)

The Mail helper and Proton's Mail SDK are AGPL-3.0-only. See
`LICENSE-MAIL-HELPER`, copied verbatim from the pinned SDK's
`project/mail/rust/LICENSE`. Copyright notices in original source are retained.
Source: https://github.com/ProtonMail/clients; revision in `upstream.lock.json`.
`Tools/ProtonXMailHelper` supplies narrow private IPC, macOS Keychain callbacks,
authentication/challenge orchestration and selected-message text rendering.
`patches/mail-core.patch` exposes the existing Rust sidebar module and adds an
opt-in feature disabling SDK logging and telemetry. `patches/mail-notifications.patch`
and `Tools/MailNotifications` add a bounded, read-only queue of committed
CREATE events for native alerts. `patches/mail-attachments.patch` exposes bounded
cache content through the existing SDK read/decryption adapter for explicit native
attachment export. Cryptography is unchanged.
The build excludes unpublished workspace members and uses the public crates.io
index instead of Proton's internal mirror. `Resources/MailHelper.lock` pins all
resolutions. The helper also uses security-framework and html2text; original
dependency licenses must accompany binary distribution. The Swift UI remains
GPL-3.0-or-later; review all applicable AGPL and combined-work obligations before
distributing the complete suite. No public binary release is made by this change.

## Opt-in Mail storage candidate

`Tools/MailStorage` is AGPL-3.0-only and part of the Mail helper's corresponding
source. The `secure-storage` feature uses rusqlite's
`bundled-sqlcipher-vendored-openssl` provider. SQLCipher is BSD-3-Clause;
OpenSSL is Apache-2.0. Original SQLCipher/OpenSSL license and notice files must
accompany any candidate binary distribution. The new lockfile adds
`openssl-src 300.6.1+3.6.3`; existing package versions remain pinned.
Sources: https://github.com/sqlcipher/sqlcipher and https://github.com/openssl/openssl.
The default helper does not enable this candidate. No public binary is released.

## Reference source (downloaded for review; not linked or redistributed)

- ProtonMail/WebClients: desktop Mail/Pass UX, authentication and OS integration.
- protonpass/ios-pass: Swift architecture and existing macOS placeholder.
- ProtonMail/ios-mail: native Mail architecture.
- protonpass/proton-pass-common: Pass models and serialization contract.
- ProtonMail/proton-bridge: local IMAP/SMTP behavior and TLS certificate identity.

All URLs and immutable revisions are recorded in `upstream.lock.json`.
Reference repositories retain their own licenses. `scripts/bootstrap.py
--references` fetches them for inspection.

## Binary distribution

Do not distribute a helper-containing binary without the corresponding source
and dependency notices. `scripts/source-bundle.sh` creates a source bundle with
both pinned helpers, patches, Cargo lockfiles, vendored Rust dependencies and their
licenses. Keep the resulting bundle beside any binary, and include this file and
`LICENSE` and `LICENSE-MAIL-HELPER` in the app. No official Proton release binaries are repackaged.

Several exact Proton registry packages omit license declarations/root license
files. The local source archive is for review; binary and complete vendored-source
publication remains pending resolution of [the recorded license review](docs/LICENSE_REVIEW.md).
