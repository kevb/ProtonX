# Validation record

Dates: 2026-10-05–06. Apple Silicon Mac, macOS 26.6.2, Xcode 27 / Swift 6.4,
Rust 1.99.0. Automated test content is synthetic. User-driven live sign-in and
local unlock reached a vault workspace in the morning follow-up. Only fixed UI
states were inspected; no live vault contents were returned to the model.

## Completed

The following is the overnight record; the morning follow-up below supersedes
its desktop-handoff status.

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
  and native app bundle rebuild passed. The corrected account handoff reached
  a connected vault workspace after user authentication and macOS local unlock,
  with creation enabled and no error alert. Only these fixed UI states were
  inspected; no account identifiers, vault titles, item contents or credentials
  were returned to the model. Remote synthetic-item CRUD, restart and recovery
  still need validation. This observation does not validate the experimental
  direct-password flow or every account challenge.
- The feature comparison and next acceptance gates are recorded in
  [GAP_ANALYSIS.md](GAP_ANALYSIS.md).

## Native editor and UX follow-up, 2026-10-06

- 48 Swift tests passed; one optional Bridge fixture test was skipped in the plain
  test run. Four app-store tests use injected synthetic runners and cover immediate
  filter/detail consistency, full create/edit/Trash/restore/lock, preview account
  isolation and a confirmed create followed by failed refresh.
- 115 original CLI tests, 122 desktop-helper tests and 252 SDK unit/integration
  tests passed. The two upstream fixture-dump helpers remain ignored. New coverage
  checks secret-free summaries, modern URL mode preservation, unsupported custom
  field preservation, custom-index/deletion correctness, active-item TOTP limits,
  original CLI command/policy separation and native command allowlisting.
- The synthetic SDK server confirms that native creation encrypts login notes,
  multiple websites and a hidden custom field using the original request path.
  Native create/update against a read-only share never reaches a write endpoint.
  A changed item revision is refused before decrypt/encrypt/write; the existing
  server revision guard remains on the final update request.
- Verification-code copy uses a native command that rechecks the current plan and
  active configured-item ranking. It returns only the generated code; the UI's
  previous capability snapshot is not the sole access check.
- Release helper, Swift app and separate ad-hoc signed **ProtonX Update.app** and
  **ProtonX Preview.app** bundles built and verified. The running real bundle was
  not replaced. The preview forces synthetic Pass data and refuses account login,
  Mail access, additional menu-bar registration and global shortcut registration.
- Synthetic native-control walkthrough passed collection selection, creating a
  login with notes/multiple websites/hidden custom field, editing websites, invalid
  URL rejection with draft retention, corrected save, Trash, restore and account
  actions. Keyboard Find focused search, repeated Find replaced the old query,
  and search cleared hidden selected details. Automatic inactivity lock was also
  observed in the preview. No primary-account contents were inspected or changed
  by these checks; the supplied official screenshot was a layout reference only.
- The compile-only credential-provider probe passed Swift 6 typechecking with
  warnings treated as errors and 20 synthetic origin candidate cases. It is not
  embedded, installed, registered or capable of returning credentials. The offline
  source review found no persisted complete item cache in this pinned helper.
- Rust formatting used the repository-local Rustup toolchain under `.tools`; the
  formatter component was installed there. No global dependency was installed.

See [GAP_ANALYSIS.md](GAP_ANALYSIS.md), [CREDENTIAL_PROVIDER.md](CREDENTIAL_PROVIDER.md)
and [OFFLINE_DESIGN.md](OFFLINE_DESIGN.md) for the remaining acceptance gates.
Live remote writes, restart/recovery and a matched resource benchmark are still
unverified. Current source-archive checks remain mandatory in CI.

## Not established

- Repeated desktop account-fork login and first-vault setup across account types,
  remote vault CRUD/sync,
  TOTP/second/extra-password challenges,
  session expiry/revocation and recovery. Upstream implementation is reused but
  does not eliminate integration risk.
- Real Proton Bridge account interoperability, remote delivery, thread semantics,
  arbitrary MIME/charset encodings and large/complex mailbox behavior.
- Repeated Touch ID/Mac-password recovery after app restart with a persisted
  desktop session. One user-driven local unlock was observed; synthetic automated
  tests do not touch account Keychain data.
- Automated sleep/screen-lock and user-switch tests; code listens for system
  notifications, while synthetic UI lock was manually verified.
- Intel GUI interaction, minimum-macOS-14 runtime, controlled memory/energy comparison,
  independent security audit, Developer ID signing/notarization.
- Full official-client feature parity: autofill/passkeys/attachments/sharing,
  account switching/offline Pass UI, direct Mail auth, and Drive.

See SECURITY.md, ROADMAP.md and PERFORMANCE.md for boundaries. A successful
synthetic test is not a claim that a real account has been validated.
