# Roadmap

## Before a daily-use Pass release

- Disposable-account end-to-end SRP login, TOTP, two-password and extra-password tests.
- Session invalidation, revoked key, expired account and network recovery tests.
- Native Password AutoFill and passkey/security-key support with system extensions.
- Attachments, sharing, identities/cards/Wi-Fi creation/editing, vault management.
- Offline browse with reviewed local locking and recovery behavior.
- Large vault performance and schema fixture upgrade coverage.
- Developer ID signing, notarization, source-compliant releases and security review.

## Mail

- Verified account interoperability and richer MIME parsing.
- Paging, threading, read/unread controls, archive/trash, reply and attachments.
- Bridge lifecycle/menu-bar coordination, with consent and version checks.
- Investigate direct native Proton authentication/core integration without
  rewriting cryptography or breaking the separate product session model.

## Drive and packaging

- Evaluate Proton's supported native SDK/CLI and File Provider constraints.
- Decide separate process/sandbox packaging after proving the suite UX and IPC needs.
- Measure total memory/CPU (including Bridge and transient helpers) before publishing
  any reduction percentages.
