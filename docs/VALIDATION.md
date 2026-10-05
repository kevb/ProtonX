# Validation record

Date: 2026-10-05. Apple Silicon Mac, macOS 26.6.2, Xcode 27 / Swift 6.4,
Rust 1.99.0. All test content is synthetic. No Proton account was accessed.

## Completed

- Native Swift app compiles in debug and release; release app bundle is locally
  ad-hoc signed and verifies with strict code-signature verification.
- 26 Swift unit/contract/transport tests pass. One optional Bridge integration
  test is explicitly disabled without the local fixture configuration.
- Synthetic TLS IMAP/SMTP integration: verified certificate/hostname, mailbox
  list, UID search, header list, full message read, SMTP submission and received
  payload verification; incorrect credentials and an untrusted certificate are
  rejected. The fixture passes in both direct TLS and STARTTLS modes.
- 109 public upstream/patched Pass CLI tests pass, including four added native
  JSON reply tests (whitespace/newlines, EOF cancellation, wrong JSON type, bound).
- Native UI inspected with synthetic data: welcome, search, concealed item
  details, create sheet, password generation, item insertion, ⌘L lock clearing
  content, ⌘2 opening a separate Mail window, synthetic inbox, and shared settings.
- Menu-bar preference toggled off and back on. Quick-access preference registers
  successfully; the global shortcut was not confirmed by injected UI keystrokes.
- Core tests cover no secrets in create/update arguments, metadata-only listing,
  unsupported URL blocking, clipboard ownership, epoch invalidation, MIME plain
  text/HTML-only handling, header injection, Unicode mail encoding, helper error
  sanitization, large stdin payloads, process deadlines, cancellation, and cancellation of a pending credential prompt.

Tests caught and fixed a short-read deadlock in credential IPC and Unicode CRLF
handling in subject validation. Runtime reads use `read(2)` on utility queues,
so short challenge records are handled immediately without blocking the Swift
cooperative executor. Clipboard ownership and stale-result policies have unit
coverage; system-level interaction is not fully automated.

## Not established

- Real Proton login, remote vault CRUD/sync, TOTP/second/extra-password challenges,
  session expiry/revocation and recovery. Upstream implementation is reused but
  does not eliminate integration risk.
- Real Proton Bridge account interoperability, remote delivery, thread semantics,
  arbitrary MIME/charset encodings and large/complex mailbox behavior.
- Touch ID/Mac-password prompts with a persisted real account; Keychain storage
  with a user's Proton credentials. Automated tests don't touch account Keychain data.
- Automated sleep/screen-lock and user-switch tests; code listens for system
  notifications, while synthetic UI lock was manually verified.
- Intel runtime, minimum-macOS-14 runtime, controlled memory/energy comparison,
  independent security audit, Developer ID signing/notarization.
- Full official-client feature parity: autofill/passkeys/attachments/sharing,
  account switching/offline Pass UI, direct Mail auth, and Drive.

See SECURITY.md, ROADMAP.md and PERFORMANCE.md for boundaries. A successful
synthetic test is not a claim that a real account has been validated.
