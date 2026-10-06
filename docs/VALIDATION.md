# Validation record

Dates: 2026-10-05–06. Apple Silicon Mac, macOS 26.6.2, Xcode 27 / Swift 6.4,
Rust 1.99.0. Automated test content is synthetic. A live sign-in was separately
attempted with the account owner's authorization; no vault contents were accessed.

## Completed

- Native Swift app compiles in debug and release; release app bundle is locally
  ad-hoc signed and verifies with strict code-signature verification.
- Independent GitHub CI on macOS 15 Intel passed Swift contracts, both synthetic
  Bridge TLS modes and the release app build (run 37376926535).
- Local corresponding-source archive matches every tracked input of the patched
  helper. Its desktop-feature release build passes with `--offline --locked` and
  a fresh Cargo home containing no registry cache. Git workspace-root licenses
  are included separately; package-level license gaps are recorded before release.
- 34 Swift unit/contract/transport tests pass. One optional Bridge integration
  test is explicitly disabled without the local fixture configuration.
- Synthetic TLS IMAP/SMTP integration: verified certificate/hostname, mailbox
  list, UID search, header list, full message read, SMTP submission and received
  payload verification; incorrect credentials and an untrusted certificate are
  rejected. The fixture passes in both direct TLS and STARTTLS modes.
- Native live sign-in reached successful Proton authentication, followed by the
  upstream CLI eligibility rejection. The app now distinguishes that outcome
  without exposing credentials or raw server responses. A later direct desktop
  sign-in was rejected with HTTP 422 / API 8004. The exact cause is unresolved;
  the same response was reproduced using an obviously synthetic identity. The
  opt-in validation tool confirmed removal of its temporary test password from
  local Keychain. No real vault contents were accessed or modified. Desktop
  account-fork sign-in and full vault interoperability remain unvalidated.
- 114 public upstream/patched Pass CLI tests pass in each mode, including four native
  JSON reply tests (whitespace/newlines, EOF cancellation, wrong JSON type, bound),
  two desktop/CLI product-policy tests, two command-surface tests and a
  metadata-only TOTP summary test. Default and desktop builds both run them.
- 248 public Rust SDK unit/integration tests pass. Two intentional fixture-dump
  helpers are ignored upstream. A fork URL test checks the desktop/CLI child
  identity and that the encryption key stays in the URL fragment.
- Native authentication IPC carries a synthetic fork URL only through private
  challenges. URL-policy tests reject other hosts, credentials, HTTP, unexpected
  ports, redirect parameters and missing payloads. The signed app started the
  handoff without entering credentials; Cancel returned to welcome and terminated
  its helper. A successfully authenticated account handoff was not exercised.
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

## Morning follow-up, 2026-10-06

- The original desktop handoff returned HTTP 422/API 8004 before the account
  window could open. Credential-free requests with the pinned desktop identity
  confirmed that `POST /auth/v4/sessions` returns those codes, while fork creation
  at both `/auth/sessions/forks` and `/auth/v4/sessions/forks` succeeds. No response
  bodies, fork codes, selectors, tokens or account data were logged.
- Desktop handoff now uses Muon's existing public `from_fork().with_code()` flow,
  which skips anonymous-session creation on fork requests. CLI login and its
  eligibility policy retain the original implementation. The existing Proton
  payload decryption implementation is reused; malformed/tampered payloads are
  rejected, and fork credentials are removed before validating the payload.
- Local verification passed: 34 Swift tests (plus the optional Bridge test
  skipped), 114 helper tests in each product mode, and 249 SDK unit/integration
  tests, with two intentional fixture-dump helpers ignored. The release helper
  and native app bundle rebuild passed. The corrected account handoff progressed
  past the previous immediate rejection. A successfully completed sign-in and
  remote synthetic-item workflow still need user validation.
- The feature comparison and next acceptance gates are recorded in
  [GAP_ANALYSIS.md](GAP_ANALYSIS.md).

## Not established

- Successful desktop account-fork login and vault setup, remote vault CRUD/sync,
  TOTP/second/extra-password challenges,
  session expiry/revocation and recovery. Upstream implementation is reused but
  does not eliminate integration risk.
- Real Proton Bridge account interoperability, remote delivery, thread semantics,
  arbitrary MIME/charset encodings and large/complex mailbox behavior.
- Touch ID/Mac-password prompts with a persisted authenticated desktop session.
  Synthetic automated tests don't touch account Keychain data; the separate,
  authorized live attempt used a temporary credential in local Keychain.
- Automated sleep/screen-lock and user-switch tests; code listens for system
  notifications, while synthetic UI lock was manually verified.
- Intel GUI interaction, minimum-macOS-14 runtime, controlled memory/energy comparison,
  independent security audit, Developer ID signing/notarization.
- Full official-client feature parity: autofill/passkeys/attachments/sharing,
  account switching/offline Pass UI, direct Mail auth, and Drive.

See SECURITY.md, ROADMAP.md and PERFORMANCE.md for boundaries. A successful
synthetic test is not a claim that a real account has been validated.
