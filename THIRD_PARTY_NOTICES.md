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
the pinned helper, the patch, Cargo lockfile, vendored Rust dependencies and their
licenses. Keep the resulting bundle beside any binary, and include this file and
`LICENSE` in the app. No official Proton release binaries are repackaged.
