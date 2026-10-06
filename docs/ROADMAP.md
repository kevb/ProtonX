# Roadmap

See the [2026-10-06 official-client gap analysis](GAP_ANALYSIS.md) for the
ordered Pass-first work plan and acceptance gates. Sign-in and a verified
end-to-end workflow come before additional products.

## Completed native foundations

- Atomic metadata/Trash snapshot, permission-aware actions and last-success state.
- Native selection, filters, sorting, empty states and synthetic preview isolation.
- Login/note editing with multiple websites, notes, TOTP and text/hidden custom fields.
- Revision conflict protection, draft retention and acknowledged-save handling.
- Compile-only AutoFill feasibility contracts and offline storage review.

These have synthetic/source validation; remote writes and recovery are still gates.

## Before a daily-use Pass release

- Validate the new desktop protocol backend on non-CLI-eligible accounts,
  preserving the original CLI product policy and server product limits.
- Disposable-account desktop-fork interoperability and cancellation/recovery tests.
- Resolve direct SRP rejection (HTTP 422/API 8004); TOTP/two/extra-password tests.
- Session invalidation, revoked key, expired account and network recovery tests.
- Native Password AutoFill and passkey/security-key support with system extensions.
- Attachments, sharing, identities/cards/Wi-Fi creation/editing, vault management.
- Offline browse with reviewed local locking and recovery behavior.
- Large vault performance and schema fixture upgrade coverage.
- Developer ID signing, notarization, source-compliant releases and security review.

## Mail

- **Required onboarding: native Proton sign-in → decrypted inbox → session
  restoration.** No manual server settings in the normal experience. See
  [the direct Mail core decision and acceptance gates](MAIL_NATIVE_SIGN_IN.md).
- Native Mail core build, private IPC, native authentication states, reader and
  separate session restore are implemented with synthetic tests. Prove real
  sign-in/decryption/restart on a designated account and review release licensing.
- Native credential/challenge UI with separate Mail session/Keychain storage;
  synthetic contracts followed by designated disposable-account validation.
- Verified account interoperability and richer MIME parsing.
- Paging, threading, read/unread controls, archive/trash, reply and attachments.
- Retain Bridge as an optional prototype/compatibility path. Its lifecycle work
  is secondary to proving direct native Mail onboarding.

## Drive and packaging

- Evaluate Proton's supported native SDK/CLI and File Provider constraints.
- Decide separate process/sandbox packaging after proving the suite UX and IPC needs.
- Measure total memory/CPU (including Bridge and transient helpers) before publishing
  any reduction percentages.
