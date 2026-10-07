# Validation record

Last updated: 2026-10-07. Local validation environment: Apple Silicon Mac,
macOS 26.6.2, Xcode 27 / Swift 6.4 and Rust 1.99.0. Automated test content is
synthetic and uses isolated storage. Private account contents and credentials
are excluded from public artifacts.

## Current coverage

| Area | Evidence | Remaining acceptance |
| --- | --- | --- |
| Pass account workflow | Manual fictional-login creation, bidirectional edit/sync with the official desktop app, conflict refusal, Trash/restore and online quit/restart | Broader item/account types, real server expiry/revocation and upgrade/Keychain continuity |
| Pass saved/offline browsing | Synthetic encrypted-storage, policy, saved-first/reconnect and lock-race tests | Disconnected account restart and larger-vault measurements |
| Native Mail | Manual sign-in and message reading; synthetic/public tests for reading, composer, sender selection and message actions | Live send/reply delivery, linked-Gmail delivery and account recovery |
| Mail secure storage | Opt-in database/file encryption and resumable database/attachment staging contracts | Cache path rebasing/activation, whole-profile cutover and pending-send/draft recovery before enabling ordinary builds |
| Product launchers | Synthetic native UI checks for cold/warm requests, minimized/closed windows and reverse product selection; signed installer checks | Minimum-OS runtime and update/Keychain continuity |

The latest local Swift run passed 120 tests (62 core, 58 app); five synthetic
atomic-install tests passed. These are local results, not a statement about the
latest GitHub run. Dated entries below record milestone-specific test scope and
historical limitations. The README and roadmap describe the current feature set.

## Existing Mail attachment staging, 2026-10-07

- Added resumable encryption of existing attachment/embedded-MIME cache files,
  retaining originals and recording source paths, hashes and progress only in an
  encrypted plan. Generic output names and private permissions prevent staging
  from introducing plaintext attachment filenames or contents.
- Eleven new parent tests cover six process-death checkpoints, unchanged resume,
  empty/absent caches, wrong keys, damaged/missing outputs, changed cache/database
  sources, unsafe paths/links, size limits, private permissions and invalid plans.
  Subprocess drivers are excluded from ordinary discovery and executed by their
  parent crash tests. The pinned SDK-schema fixture now preserves attachment
  path/size metadata alongside body/draft/opaque queue rows without execution.
- `scripts/test-mail-storage.sh` passed 52 tests (18 helper, 34 storage/SDK), the
  opt-in helper build and ten synthetic startup-refusal contracts. Resolved
  dependency checks confirmed that normal helper builds do not enable SQLCipher.
  The upstream debug-linker unwind-size warning remains; it did not fail the build.
- Validation used isolated synthetic profiles, with no account, Keychain or
  installed-profile migration. SDK absolute paths remain unchanged. Ordinary app
  builds do not invoke staging; cache path rebasing, cutover/recovery and genuine
  pending-send recovery remain activation gates.

## Product launcher focus correction, 2026-10-07

- Replaced duplicate per-window URL handlers and app-only activation with one
  application URL handler and a native window router. Cold-launch requests wait
  for launch completion/window creation; warm requests raise the existing target,
  unminimize it if needed, and supersede stale requests. Menus and keyboard product
  switching use this same route. Product URL validation remains closed.
- Companion launchers no longer independently activate the suite. They retain
  their adjacent-bundle identity and other-running-copy checks and do not add
  helper, account, Keychain or session access.
- 120 Swift tests passed (62 core, 58 app), including six routing tests covering
  startup ordering, scene creation, warm reuse, closed/released targets, invalid
  URLs and competing intents. Five synthetic atomic-install contracts passed.
  Account-capable/preview release builds and native launcher signature checks
  passed using the existing helpers and configured local certificate.
- Native UI checks used synthetic Preview only. Test-only launcher copies changed
  the adjacent target name/identity to Preview, leaving the routing/activation
  calls intact. Verified Mail in front after a cold launch (also after quitting
  with Pass in front), Mail over open Pass, minimized Mail restoration, closed
  Mail recreation, and the reverse Pass launcher. Preview never registers the
  production URL scheme; no real account/profile or credentials were accessed.
- The signed focus/reader update and both product launchers were installed with
  the verified atomic installer after the app closed. Installed executables match
  the tested staged build and pass strict signature verification. One complete
  previous build is retained for rollback; account profiles are unchanged.
- The preceding GitHub run exposed two Pass offline-test timing races on the
  slower Intel runner: short synthetic network delays could finish before the
  test observed saved-only state. Test-only response gates now hold online
  refresh until saved-detail assertions complete, and hold the stale cache-detail
  failure until reconnection finishes. Account/cache implementation is unchanged.

## Official-editor layout refinement, 2026-10-06

- Used official Pass editor layouts as references only; reference screenshots
  are not checked into the repository. Close and Save now remain in the header,
  title/content typography is larger, website inputs have individual outlined
  rows with remove controls, and Add website focuses the new row. Login notes
  are more compact; secure notes retain their larger writing area.
- Unchanged edits cannot save or create a new revision. A memory-only baseline
  compares editable contents; reverting changes disables Save again. Empty
  website rows do not count as a change. Conflict/refresh gates are retained.
  Baseline values are cleared when the editor closes; nothing is persisted.
- Username and Email remain separate SDK fields. TOTP secrets remain concealed
  with existing setup/plan checks. No attachment upload or unsupported password
  strength claim is added.
- 91 Swift contract/recovery tests passed. Synthetic native preview checks
  confirmed disabled/enabled/reverted Save, focus on adding a website, two URLs
  surviving save/reopen, removal enabling Save, and cancellation discarding the
  draft. Login-edit and secure-note-create layouts were visually inspected.
- Preview and account-capable release builds passed, with strict nested
  signature verification for `build/ProtonX Editor Update.app`. Existing helpers
  are unchanged. No real account was accessed during this validation and the
  running account-capable app was left intact. No public binary was released.

## False edit-conflict correction, 2026-10-06

- Reproduction: create a fictional login, view it in the official Pass desktop
  app without editing, then correct its password in ProtonX. Saving incorrectly
  raises a conflict and blocks Edit until refresh. Read-only inspection confirmed
  this failure; no passwords were revealed, copied or changed.
- Root cause: ProtonX's checked-update guard compared the API state to `0`, while
  Proton's `ItemState::Active` is `1`. It rejected valid active items even with an
  unchanged revision. The old negative fixture also used `0`, masking the mistake.
  The guard and stale-revision fixture now use the upstream enum; revision and
  non-active-state protections remain enforced before encryption/write.
- A new public mock-server contract decrypts a synthetic active login, changes its
  password (including final punctuation), executes the real checked SDK update and
  decrypts the outgoing payload to verify full content and LastRevision. It fails
  with the old guard's `NativeRevisionConflict` and passes with the correction.
  A second contract rejects Trash and unknown wire states without reaching PUT.
  Mock handlers are consumed once, so unchanged repeated reads are registered
  explicitly; no server/account or new cryptography is involved.
- Persistent Refresh Vault actions now accompany blocked-write status and error
  feedback, including after dismissing the banner. The write gate is retained.
- 91 Swift tests passed. CLI policy suites passed 115/122 tests; the native SDK
  passed 230 tests and field-update integration passed 24, with two upstream tests
  ignored. The optimized desktop helper and release app built; strict nested
  signature verification passed for `build/ProtonX Edit Fix.app`.
- The materialized helper matches the complete updated corresponding-source patch;
  dependency/source pins and notices are unchanged. A full source archive is not
  generated from the locally dirty checkout; no public binary was released.
- Official desktop search/edit is the acceptance reference; Safari website
  filling is a separate integration surface.
  The updated app was opened, local unlock completed, and the saved session
  restored the fictional login with Edit enabled. No sign-in credentials or
  hidden password were read.
- Manual account acceptance after the correction passed editing/sync in both
  directions with the official Proton Pass desktop app, conflict refusal,
  Trash/restore and online quit/restart for the fictional test record. These are
  limited manual account results, separate from automated fixtures. They do not establish server expiry/revocation, prompt-free rebuilds,
  encrypted offline browsing or interoperability for every item type.

## Pass recovery contracts, 2026-10-06

- Added regression cases that failed before the fix: uncertain Trash/restore could
  reach the helper twice, while detail/edit/Trash/restore/post-write expiry retained
  workspace data or returned to local unlock for a rejected session.
- Fixed unknown Trash/restore outcomes to require authoritative refresh before
  another write. Snapshot/detail/write expiry now clears visible data and returns
  to sign-in; an acknowledged save remains distinguished from refresh failure.
  Busy/locked action guards and authentication generation checks prevent late
  recovery from reopening the workspace or interfering with a newer sign-in.
- `swift test` passed 91 tests (58 core, 33 app), including 14 added test functions
  covering 24 recovery cases. Fixtures cover initial/reconnect failures, refreshed
  permissions, conflicts, uncertain writes, Trash restoration, session invalidation,
  denied/late unlock and responses after lock. Real disposable child processes
  exercise partial output/nonzero exit, fresh commands and pending prompt cleanup.
- Saved-session tests use an isolated dummy `.session/session.json` hint and
  scripted responses, with injected local unlock. They never decode a real Proton
  session or access account Keychain entries. They prove the app's boundary and state
  transitions, not SDK restoration, real server expiry or prompt-free signing.
- `scripts/test-helper.sh` passed CLI policy suites with 115 and 122 tests, plus
  228 public SDK tests and 24 field-update integration tests. Two upstream SDK
  tests remain ignored. Desktop identity verification passed against the pinned
  `macos-pass@1.42.0` protocol; no dependency/source pins or helper crypto changed.
- Release app build and strict nested app/helper signature verification passed for
  `build/ProtonX Pass Recovery.app`, using existing helpers and the configured local
  certificate. No running app was replaced, no app was installed in Applications,
  no account was accessed and no binary was publicly distributed.
- Durable encrypted offline browsing is still absent. Designated-account SDK
  restart and official Safari create/edit/Trash/restore acceptance remain separate
  gates. See [the coverage matrix](PASS_RELIABILITY.md).

## Startup and local storage review, 2026-10-06

- 73 Swift tests passed, including delayed first-load, failed-load/retry and
  lock-before-list-completion coverage. Initial Pass/Mail loading is distinguished
  from confirmed empty results; failed initial lists offer Retry.
- 64 Rust tests passed via `scripts/test-mail-helper.sh`: nine helper contracts,
  53 public Mail tests and two ProtonX synthetic fixtures (linked sender and local
  storage). The temporary SQLite fixture confirms decoded bodies remain readable
  without a Keychain key. It proves a missing security property, not secure caching.
- Release Swift build and strict app/helper signature verification passed for
  `build/ProtonX Loading Update.app`. The existing Mail helper source is unchanged.
- No installed account profile was inspected or migrated, no Mail was sent and
  no app was installed in Applications. No startup-speed improvement was measured.
  See [the storage correction and acceptance gates](LOCAL_STORAGE.md).

## Native Mail composer, 2026-10-06

- Manual account acceptance covers native sign-in and message reading. Public
  artifacts contain no private mailbox contents or addresses. Send/Gmail delivery,
  restart and account recovery remain separate acceptance gates.
- Implemented a native plain-text composer with From/To/Cc/Bcc, new/reply/reply-all,
  ordinary draft reopening, explicit Save/Save & Close and separate send states.
  The SDK chooses the reply identity and quote, validates sending addresses and
  handles encryption/queueing. Pending/unknown send does not become another send
  automatically. Scheduled drafts and unsupported recipient groups are refused.
- 70 Swift tests passed, including original contracts plus linked-sender payloads,
  header/envelope bounds, queue acknowledgement versus delivery, duplicate-send
  prevention, ambiguous outcome retention, explicit preflight correction,
  failed-save retention, late-composer rejection and synthetic preview isolation.
- 63 Rust tests passed: nine private-helper tests, 53 public Proton fixture/mock
  tests, and one added linked-Gmail sender/BYOE contract. Public coverage includes
  encrypted bodies, paging, draft construction, sender/signature changes,
  recipient validation, send results/failures and duplicate/already-sent behavior.
  No test reads account Keychain entries or reaches a real mailbox/recipient.
- Independent Pass/Mail protocol checks and Mail privacy/batched-save checks
  passed. The Mail source pin, crypto implementations and dependency lock remain
  unchanged; the patch exposes existing draft modules and opts only the native
  wrapper into explicit batch saving.
- Native dark/light walkthrough: synthetic Gmail reply keeps Gmail From;
  body/recipient editing, Cc/Bcc, quote disclosure, save feedback, edited-after-save
  feedback and sender/recipient confirmation work. A dialog newline display bug
  found visually was fixed and the final light-mode dialog was rechecked.
- Optimized Mail helper and release Swift app built. The separately named
  `ProtonX Mail Update.app` and both helpers passed strict signature verification;
  the already-running real app was not replaced. Materialized helper/test source
  matches the checked-in inputs byte for byte. No binary was publicly released.
- Public official composer screenshots and pinned desktop source were used as
  references. No account screenshots are committed. See [MAIL_COMPOSER.md](MAIL_COMPOSER.md).
- A manual Mail update check encountered another Keychain authorization prompt. Only the
  self-signed local certificate is available. No credential workaround or ACL
  relaxation was added; the prior failed rebuild-continuity result still applies.

## Native Mail implementation and local signing, 2026-10-06

- Direct Mail credentials/TOTP/second-password states, isolated saved-session
  restore, folders/paging, selected-message decryption and SDK account logout
  are implemented. The native helper statically links pinned Mail SDK 0.168.2.
  Bridge settings are an advanced compatibility path. The direct client is
  read-only, with explicit unsupported human verification/FIDO-only states.
- Optimized `mail-macos` helper and release Swift app built; the stripped Mail
  executable is approximately 36 MiB. This is disk size, not process RAM or an
  Electron comparison. Normal runtime has no bundled web engine. The SDK runs
  while Mail is unlocked and terminates on lock/close.
- 61 Swift tests passed, including strict Mail reply framing/IDs/bounds, private
  credentials, persistent challenge retries, helper deadlines/lock, late replies,
  cancelled-selection continuity, local-unlock cancellation, failed logout,
  expiry clearing, hidden-selection clearing and preview isolation.
- Five native Mail helper tests passed. Twelve public Proton `mail-common` tests
  passed: five encrypted message-body/MIME/attachment fixtures and seven local
  mock-server paging tests. Neither test suite accesses a real account or its
  Keychain namespace. The reproducible helper script and protocol/privacy
  verifier passed with the committed lock. No registry/Git package records were
  added to the previously tested core candidate lock; only the helper record and
  its direct dependency edges were added.
- Dark/light preview inspected with native controls: message selection, search
  clearing hidden contents, empty Sent folder, return to Inbox, locking and
  disabled sign-in. Column minimum now keeps message subjects readable. Preview
  forces synthetic data in both products and cannot open account/Bridge paths.
- App and nested helpers passed strict signature verification using the existing
  configured local certificate. The certificate is self-signed, despite its
  Developer ID-like name. A synthetic Keychain probe passed repeated launches of
  one binary and refused an ad-hoc replacement, but **failed rebuilt-executable
  continuity** (`errSecAuthFailed`) even with the same certificate/identifier.
  Its item was cleaned up. No account ACLs were changed. Local signing is supported,
  but prompt-free helper updates remain unverified; see [LOCAL_SIGNING.md](LOCAL_SIGNING.md).
- No live Mail login, mailbox contents, delivery, restart/revocation or cross-client
  interoperability was tested in this milestone. Account acceptance followed
  separately; see Current coverage.
  Normal Mac local unlock remains enabled. No binary is publicly distributed;
  AGPL/dependency and combined-work release review remains a gate.

## Direct Mail core feasibility, 2026-10-06

- Reviewed and pinned ProtonMail/clients `2ecb794dbc221384dc6d88840965ac144db301ad`
  as reference only. No production Mail SDK linkage or direct sign-in UI added.
- Unmodified public workspace metadata failed on an unpublished unrelated member.
  An isolated copy retains the 83 published members and replaces the internal
  crates.io Nexus proxy with public crates.io. The original checkout is unchanged.
- Metadata and host-native `mail-uniffi` 0.168.2 typecheck passed. Native library
  build with the candidate lock and `mail-macos-debug` profile passed, producing
  an arm64 dynamic library and static archive. An unoptimized linker warning
  concerns oversized DWARF unwind metadata; optimized builds remain untested.
- Candidate lock removes 239 unused original package records and adds no new
  registry/Git package name/version/source records. The preparation script,
  lock and commands are recorded in `Experiments/MailCore`; reproducing its
  manifest/config/lock and locked metadata passed. Existing-directory preparation
  refuses replacement, Python compilation and reference-pin checks passed.
- This is compile/link evidence only. No Mail account credentials, session,
  Keychain item, message read/send or live API authentication were exercised.
  Bindings, privacy/license review and disposable-account sign-in/decryption/
  restart are still gates. See [the decision](MAIL_NATIVE_SIGN_IN.md).

## Initial implementation, 2026-10-05

This records the initial implementation. The subsequent desktop-handoff
correction supersedes its account-login limitation.

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

## Desktop account-handoff correction, 2026-10-06

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
  inspected; validation artifacts exclude account identifiers, vault titles,
  item contents and credentials. Remote item writes and restart/recovery were
  outside this milestone's scope; subsequent acceptance is recorded above. This observation does not validate the experimental
  direct-password flow or every account challenge.
- The feature comparison and next acceptance gates are recorded in
  [GAP_ANALYSIS.md](GAP_ANALYSIS.md).

## Native editor and UX, 2026-10-06

- 48 Swift tests passed; one optional Bridge fixture test was skipped in the plain
  test run. Four app-store tests use injected synthetic runners and cover immediate
  filter/detail consistency, full create/edit/Trash/restore/lock, preview account
  isolation and confirmed create/edit/Trash followed by failed refresh. The last
  check starts with an existing selection and verifies navigation retains the
  warning while further writes remain blocked.
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
  and search cleared hidden selected details. Website removal retained the remaining
  address, and saving a new revision concealed a previously revealed password.
  Automatic inactivity lock was also
  observed in the preview. No primary-account contents were inspected or changed
  by these checks; official-app screenshots were layout references only.
- The compile-only credential-provider probe passed Swift 6 typechecking with
  warnings treated as errors and 20 synthetic origin candidate cases. It is not
  embedded, installed, registered or capable of returning credentials. The offline
  source review found no persisted complete item cache in this pinned helper.
- Local corresponding-source generation passed: every tracked patched helper
  input matched the source archive byte-for-byte. No vendor archive or binary
  was published; dependency licensing remains a distribution gate.
- Rust formatting used the repository-local Rustup toolchain under `.tools`; the
  formatter component was installed there. No global dependency was installed.

See [GAP_ANALYSIS.md](GAP_ANALYSIS.md), [CREDENTIAL_PROVIDER.md](CREDENTIAL_PROVIDER.md)
and [OFFLINE_DESIGN.md](OFFLINE_DESIGN.md) for the remaining acceptance gates.
Live remote writes, restart/recovery and a matched resource benchmark are still
unverified. Current source-archive checks remain mandatory in CI.

## Remaining acceptance gates

- First-vault setup and account challenges across account types; real server
  expiry/revocation, reauthentication and preservation of unsupported item fields.
- Pass disconnected restart, offline policy/recovery and Keychain continuity
  across rebuilds/upgrades. Manual online restart does not establish these.
- Mail send/reply delivery, linked-Gmail identities, interrupted or uncertain
  sends and pending-draft recovery; broader MIME/charset and large-mailbox cases.
- Mail whole-profile encryption cutover, existing attachment/MIME migration and
  file API audit before secure caching is enabled in ordinary builds.
- Automated sleep/screen-lock/user-switch behavior, VoiceOver coverage, Intel GUI
  and minimum-macOS-14 runtime, and matched memory/energy/startup benchmarks.
- Dependency licensing, independent security review, Developer ID signing,
  notarization and source-compliant binary distribution.

See [SECURITY.md](../SECURITY.md), [ROADMAP.md](ROADMAP.md) and
[PERFORMANCE.md](PERFORMANCE.md) for scope and release criteria.

## Manual account acceptance and native design, 2026-10-06

Initial manual account acceptance passed creation, sync and deletion of a
fictional test login. This check covered that workflow only. Cross-client editing,
conflict refusal, Trash/restore and online restart passed later in the edit-guard
acceptance milestone; permanent deletion is not implemented.

The visual design pass passed the existing 48 Swift contracts (one optional
Bridge test skipped), a release build and strict ad-hoc signature verification.
The isolated preview was inspected in both appearances. Native controls completed
synthetic keyboard creation, save, Trash confirmation, restore and collection
selection; sensitive fields remain concealed. No authentication/helper/crypto
protocol was changed. The preceding full GitHub run `37437581016` passed both
native and helper jobs; it predates these visual changes.

The subsequent editor refinement replaced settings-style rows with native inputs
in outlined cards. A synthetic note retained two lines typed with Return; a new
login retained its website, note and concealed custom field. Title focus, type
selection, scrolling, concealed input and explicit save were checked through native
controls. The existing Swift contracts and release/signature checks passed again.

## Encrypted Mail storage candidate, 2026-10-06

All fixtures and profiles in this work are synthetic. No account profile was read,
converted or installed; no account Keychain key was requested. The default app
continues to use its existing helper/storage mode.

The opt-in SQLCipher engine covers database/WAL plaintext-marker absence, keyed
restart, missing/wrong-key rejection, corruption/truncation, schema/application
version preservation, a generic pending-send row, busy conversion refusal,
profile locking and symlink refusal. An actual SDK pool stores/reloads a decoded
message body locally and reopens it with the key without a server.

A repeated SDK test exposed a graceful-exit crash after successful reads. The
candidate now joins database worker threads before pool teardown completes;
ten repeated synthetic encrypted SDK read/shutdown runs passed after the fix.
Default pool behaviour stays detached as upstream. This does not establish
complete authenticated helper runtime teardown or disconnected session restore.

Synthetic Swift store coverage verifies local → refresh → poll commands, saved
content without a false server-sync timestamp, selected body retention, failed
refresh retention and lock cancelling queued refresh. Protocol checks reject
freshness contradicting loading/failure. Candidate helper preflight tests use
only nonempty synthetic legacy/damaged/linked/locked profiles; each refuses before
SDK/Keychain initialization and preserves existing file contents.

Full-profile migration, interrupted conversion recovery, actual SDK send-queue
replay, attachment/embedded-MIME file encryption, measured startup performance,
Keychain integration with an isolated account and real-account interoperability
remain gates. The low-level export primitive is not exposed to users or invoked
by either helper mode. See [scope and build options](LOCAL_STORAGE.md).

The final Swift run passed 76 contracts. Default Mail tests passed 66 contracts
(11 helper, 53 public SDK, the plaintext baseline and linked-Gmail fixture).
Candidate tests passed 11 helper contracts, seven encrypted engine/SDK fixtures
and four actual-helper startup refusal cases. The first default scroller run
failed only its strict mock request count (expected three, received two) despite
returning the expected item. A full rerun passed without source/test changes;
this timing-sensitive upstream failure remains recorded rather than relaxing its
assertion. Local success is not a report that new GitHub CI has passed.

Both default and opt-in encrypted helper optimized builds passed. The optimized
candidate also passed the four synthetic startup refusal cases. The native
release app built and passed strict nested signature verification, staged at
`build/ProtonX Storage Preparation.app`. It packages the default helper, was not
launched and was not installed in Applications. No existing account profile was
converted. The candidate helper remains separate in `.tools/mail-helper-secure`.

## Resumable Mail database staging, 2026-10-06

This work used temporary synthetic profiles and public local mock-server tests.
No installed profile or account Keychain key was read; no account data was
converted and no production migration action was enabled.

The database-set coordinator passed 19 engine/SDK contracts: eleven migration
contracts, six existing storage contracts, encrypted SDK local-body/reopen and
SDK-schema migration preservation. The subprocess-only crash driver is marked
ignored for ordinary test enumeration; migration tests invoke it explicitly at
six durable transition points and require abrupt exit followed by successful
resume. Originals are retained. Wrong-key resume before any completed export,
committed WAL data, source changes, invalid/missing manifests, damaged/missing
acknowledged stages, reserved/non-ASCII URI paths, format markers, linked paths,
permissions and staged plaintext-marker absence are covered.

The SDK-schema fixture preserves a decoded body, draft references, opaque action
queue bytes and the complete schema. It never dispatches that queue; it is not a
proof of real pending-message replay or duplicate-delivery prevention.

Swift passed 77 contracts, including typed retained-storage failures. Default
Mail passed 66 helper/public SDK contracts plus eight actual-helper startup
refusals. The candidate passed eleven helper contracts plus seven actual-helper
startup refusals. Resolved production dependency checks confirm normal builds use
the shared guard without enabling the SQLCipher/encryption feature. Both updated
helpers refuse a pending migration; a normal helper also refuses encrypted files
or an unsupported format before SDK initialization. Historically older builds
remain outside this guard protocol.

A first staging attempt exposed the read-only-main/attached-destination write
restriction. The final export opens the encrypted destination as main, attaches
the source with an escaped read-only URI and verifies its actual SQLite read-only
flag before export. All migration and SDK-schema fixtures passed after this
correction; sources are never forced through a checkpoint during staging.

Whole-profile cutover/recovery UI, attachment/MIME encryption, actual send replay,
older-build exclusion, isolated Keychain integration and measured startup costs
remain activation gates. Source preparation/privacy contracts and documentation
links were verified. This is local validation, not a report of GitHub CI success.

Both optimized helper builds passed with the final process-exit lock lifetime;
the optimized normal/candidate helpers also passed all eight/seven synthetic
startup refusal cases. Both modes' eleven helper contracts were rerun after the
shutdown change. The native release app passed strict nested signature verification
and is staged at `build/ProtonX Migration Preparation.app`, packaging the normal
helper. It was not launched or installed in Applications. Debug SDK linking emitted
the existing large-unwind-table warning; optimized builds completed successfully.
No new public binary or corresponding-source archive was released.

## Encrypted Pass saved-first/read-only cache, 2026-10-06

The durable item-cache absence recorded in the earlier offline review is superseded
by this milestone. [OFFLINE_DESIGN.md](OFFLINE_DESIGN.md) describes the implementation
and remaining acceptance; this feature does not change Mail storage.

- 101 Swift contracts passed. New coverage exercises saved metadata and one selected
  detail before a delayed online response; separate local read scheduling; read-only
  actions/no queued writes; reconnect with changed permissions; missing/corrupt/
  expired cache fallback; TLS/authentication/session invalidation refusal; lease
  bounds/clock rollback; expiry timers; lock races and late cache errors after
  reconnect. Test responses are synthetic; local unlock is injected only in tests.
- The full helper suite passed: 115 original CLI tests, 131 desktop-helper tests,
  232 SDK unit tests and 24 update integration tests. Two upstream fixture-dump
  helpers remain ignored. Eight new SQLCipher/storage/session contracts exercise
  encrypted close/reopen, missing/wrong keys without reset, database truncation,
  corrupt item content, generation/schema/account/session/lease checks, atomic
  rollback, explicit invalidation and actual encrypted session restoration without
  a network client. Two SDK tests preserve original ciphertext/key rotation and
  reject incomplete decrypt snapshots. Error classification retains caches only
  for connection errors, including wrapped errors.
- Tests inspect disposable database files for synthetic plaintext markers and
  confirm selected credentials decrypt through Proton's existing crypto. This is
  evidence about the fixture/database, not a whole-machine plaintext audit or
  memory-zeroization guarantee.
- Desktop source identity verification passed against `macos-pass@1.42.0`. A fresh
  pinned-source extraction plus the complete tracked helper patch matched every
  materialized helper build input byte-for-byte. Dependency and source pins are
  unchanged. The full source archive remains a CI gate; no binary/vendor archive
  is publicly distributed by this milestone.
- No real account/profile or Keychain credential was accessed, no Mac connection
  was disabled, and no running app was replaced. Disconnected real-account restart,
  Keychain update continuity, larger-vault performance and measured startup gains
  remain unverified. Free/managed accounts stay online-only; the personal paid
  lease lasts at most 24 hours and cannot discover server revocation offline.

The final packaged update built optimized Pass/Swift code and passed strict nested
app/helper signature verification using the existing configured local certificate.
It is staged at `build/ProtonX Offline Update.app`; no running bundle was replaced
and no app was installed in Applications. Mail uses the existing default helper.
The final helper source comparison passed again after cleanup handling was adjusted
to preserve the original authentication/session failure if cache invalidation also
fails. Swift's actual process deadline now emits the typed timeout error, tested
with a disposable child process; a separate store test confirms the saved view
remains read-only after that deadline. The final desktop-helper rerun passed all
131 tests. GitHub CI is queued; these results are local validation, not a claim
that the new CI run has completed.

## Mail design — 2026-10-06

- All 101 Swift contracts passed after the final Mail layout changes. Helper,
  authentication, storage and sending protocols were unchanged; the previously
  validated helper binaries were reused for this appearance-only build.
- Native synthetic previews were inspected in dark and light appearances. Reader
  and composer bodies remain white with fixed dark text; surrounding Mail chrome
  follows appearance. Sender initials are generated locally. The Bridge reader
  shares the compiled paper component; a live Bridge account was not exercised.
- The dark preview walkthrough verified message selection, no-result search
  clearing the old reader, clearing search, expanding the reader and restoring the
  mailbox. Reply all retained the synthetic connected-Gmail sending identity.
  Typed composer text was readable in both appearances; Save & Close completed
  the synthetic draft flow. These preview actions do not prove server draft sync.
- This change retains the existing plain-text reader and composer. HTML rendering,
  remote images, attachments and additional mailbox actions were not added.
- Optimized normal and preview app bundles built successfully. The final update
  uses the configured local signing identity and passed strict nested signature
  verification. It is staged at `build/ProtonX Mail Design Update.app`; the running
  account-capable app was not replaced. No real account was accessed for this
  design validation, and private reference screenshots were not added to Git.

## Formatted native Mail reader — 2026-10-06

- All 105 Swift contracts passed in the final run. New coverage bounds the
  additive HTML reply field, preserves text-only compatibility, clears rich bodies
  on selection/lock and rejects late results. An earlier run hit an existing
  Pass wait contract's deadline during heavy compilation; later full runs passed
  without changes to Pass behavior.
- All 15 Mail helper tests passed, including four reader contracts covering styled
  newsletter tables/headings/lists/quotes/entities, malformed markup, literal
  plaintext, sanitizer removal of active content, disabled remote/embedded content
  and depth/size bounds. The helper uses the already-pinned Proton transformer;
  the lockfile adds its direct dependency without changing package versions.
- All 55 selected upstream/developer Mail contracts passed (paging, body
  decryption, storage boundary, constructors, recipients, sending and linked-Gmail
  sender handling), plus eight synthetic helper storage-preflight refusals.
  Independent native Mail identity/privacy/source contracts passed.
- Native WebKit contracts exercised structure and content replacement, white
  paper, disabled inline scripts/event handlers, a closed external-link policy
  and cancelled in-view navigation. A disposable local endpoint received zero
  requests from image, frame, script and CSS URLs in the synthetic document.
  This tests the renderer's defenses independently of helper sanitization.
- Dark/light previews showed a synthetic newsletter with styles, headings, a
  table, lists and a quoted reply. The native walkthrough verified expanded-reader
  reflow, full-body scrolling, external-link confirmation/cancellation, switching
  between formatted/plain views, selecting a plaintext fixture and lock.
  No account or private message was accessed; reference screenshots were
  not copied into the repository.
- Images (including embedded images) and attachments remain unavailable. This
  adds rich reading, not a rich editor or new sending behavior. Bridge retains
  its existing plaintext reader. See [MAIL_RENDERING.md](MAIL_RENDERING.md).

The optimized Mail helper and normal Swift app built successfully. The staged
`build/ProtonX Mail Rendering Update.app` passed strict nested signature
verification using the configured local certificate. No running account-capable
bundle was replaced, and no app was installed in Applications. CI results remain
separate from these local checks.
