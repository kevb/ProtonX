# Security

ProtonX 0.1 is an unaudited developer alpha. Report suspected vulnerabilities
privately through the repository's GitHub security advisory mechanism; do not
include passwords, tokens, real message bodies or vault exports in public issues.

## Boundaries

- Proton's existing Rust library handles Pass authentication, encryption, encrypted
  session storage, encrypted local database and server sync. ProtonX adds UI and
  IPC; this entire app has not inherited any upstream audit certification.
- The helper uses a dedicated profile under
  `~/Library/Application Support/ProtonX/Pass/.session` and a Keychain service
  `org.kevb.ProtonX.Pass`. It cannot silently reuse the official CLI's legacy key.
- Mail's Bridge configuration is in the local Keychain service
  `org.kevb.ProtonX.Mail`, account `bridge`. It is not iCloud-synchronized. The
  preference `mailConnected` is a Boolean only.
- Native Mail uses Proton's pinned Rust Mail SDK in a separate helper, profile
  `~/Library/Application Support/ProtonX/Mail`, and Keychain service
  `org.kevb.ProtonX.Mail.Native`. The SDK protects session tokens/key secrets with
  a Keychain-backed encryption key, but its Mail data database is ordinary SQLite.
  Subjects, participants and previously decrypted bodies can persist unencrypted
  in that database and its journals. Local UI lock does not encrypt or remove them.
  This is an unresolved release blocker; see docs/LOCAL_STORAGE.md and its synthetic
  storage contract. An opt-in SQLCipher candidate keys new SDK databases with a
  separate Mail storage Keychain key; normal builds do not enable it. Existing
  plaintext profiles are refused, not converted. A synthetic-tested migration
  coordinator stages encrypted database copies while retaining originals; no
  production upgrade/cutover is exposed. Both updated helpers lock the profile
  and refuse pending migrations before Keychain/SDK access. Normal builds also
  refuse encrypted profiles, avoiding SDK reset behavior. Historical older builds
  do not honor these guards. Attachment file caches, whole-profile cutover and
  actual draft/send recovery remain release gates. See docs/MAIL_STORAGE_MIGRATION.md.
  It never reuses Pass or Bridge credentials. `nativeMailConnected`
  is an untrusted Boolean hint; reopening requires local unlock and SDK restore.
  Native credentials/challenges travel on private stdin. Human verification and
  FIDO-only challenges fail explicitly; no product limit or challenge is bypassed.
  The helper persists only while Mail is unlocked. Lock/close terminates it,
  cancels queued requests and clears visible contents. It may retain its encrypted
  session on disk; lock is not remote logout. Sign-out uses the SDK's account logout.
- Main Proton passwords travel through a private pipe and are not stored in UI
  preferences, argument lists, credential environment variables or logs. Decrypted
  Pass item data lives in app memory while open; Mail's core also persists decoded
  message bodies as described above. Swift strings/copies
  cannot offer reliable zeroization; clearing UI references is not a memory scrub.
- Primary sign-in displays Proton's account page in macOS authentication services
  with an ephemeral browser session. The fork URL contains a one-use code/key;
  it travels only through private IPC, remains in memory and is never logged or
  passed in argv. Only the production Proton account destination is allowed.
  The existing SDK polls and decrypts the handoff. The system authentication UI
  has its own browser process; ProtonX does not embed a persistent web product UI.
- Desktop mode exposes only native UI commands; it rejects CLI automation,
  agents, PATs, bulk secret export, process injection and permanent deletion.
- Local unlock uses `LAContext.deviceOwnerAuthentication`: Touch ID or the Mac
  password. A UI lock doesn't revoke the remote session or defend against malware
  running as the same macOS user and accessing that user's login Keychain.
- A shared app process is a shared address-space boundary, not independent product
  isolation. This build is not App Sandbox confined. Do not describe it as sandboxed.
- Helpers have a minimal environment; debug/proxy/key-provider/password overrides
  aren't inherited. No shell processes interpret user input. Create/update secrets
  are on stdin; list results contain no bulk secret fields. Only credential prompt
  records and a closed set of failure categories with numeric HTTP/API codes are
  parsed from stderr; raw server errors and all other stderr are discarded.
- Native item drafts are bounded to 256 KiB and use private stdin. One metadata
  snapshot includes active/trashed item summaries, permissions and plan limits,
  without usernames, notes, passwords or TOTP setup secrets. Secrets are fetched
  only for a selected item. Unsupported content remains in Proton's edit path.
- Native edits require the selected item's revision. The SDK checks it before
  encryption/write and sends the matching server revision; stale changes are
  refused. Shared-vault create/update checks run again in the native SDK path.
  Unconfirmed writes are not automatically retried or queued. Verification-code
  copy rechecks the current plan and active-item ranking in the helper; it does
  not rely solely on a previously loaded UI capability record.
- Pass session invalidation clears the visible workspace and returns to sign-in
  across snapshot, detail and write paths, including post-write refresh. Rejected
  The UI adds no saved-file deletion; Proton's existing invalidation/cleanup path
  remains responsible for SDK session files. The in-memory invalidation flag does
  not prove a session valid after restart. Saved-session opening requires macOS local unlock
  before helper access; refresh does not restore a locked workspace. Unconfirmed
  Trash/restore blocks further writes until authoritative refresh, as edits do.
- Responses are bounded (16 MiB); process deadlines and cancellation bound hangs.
  Selected-item and session generation checks reject stale results after lock.
- Clipboard writes use concealed/transient/autogenerated markers and expire after
  30 seconds only if ProtonX still owns that pasteboard generation. Those markers
  are requests; other apps can ignore them or capture a copy before it expires.
- Bridge Mail endpoints are literal loopback IPs; proxies/redirects are disabled. TLS and
  hostname/certificate checks are mandatory, using an explicitly imported public
  certificate. Private-key imports are refused. Mail credentials go only to Bridge.
- Native Mail has a closed command schema, 64 KiB requests, 8 MiB replies, a
  1,000-message window limit and 2 MiB rendered-body limit. No raw SDK errors,
  helper stderr or credentials are logged. Its opt-in SDK feature disables the
  logger and telemetry; automatic issue reports are discarded. Production API
  transport, authentication, account limits and decryption remain in Proton's core.
- Native Mail composer operations use the core's draft constructors, sender
  validation, Reply-To handling, encrypted save and send queue. The native feature
  disables immediate per-field auto-save in the SDK wrapper; an explicit complete
  batch is validated before save/send. Signatures and new reply quotes remain
  core-managed. Only core-offered From addresses are permitted, with a visible
  warning when the receiving identity is unavailable. Delivery success comes
  from the core's stored send result, not its initial queue acknowledgement.
  Unknown delivery never triggers another app-level send; the underlying core's
  queue can continue on restore. Lock/close does not cancel remote delivery.
  New text is limited to 32 KiB, recipients to 100 distinct addresses and subjects
  to 998 bytes without control characters. Editor text is not persisted in
  preferences. Save explicitly before lock; unsaved UI text is discarded.
- Mail renders plain text. HTML, scripts and remote images are not loaded. Native
  HTML is converted to text without a browser; the SDK owns MIME/decryption. The Bridge MIME
  reader is intentionally limited, with bounded recursion; it is not a complete
  standards-compliant MIME implementation. Attachments are counted, not opened.
- No telemetry is added. Upstream Pass telemetry is disabled. Upstream automatic
  update checks are skipped by the patched helper in native mode. No auto-updater
  silently replaces this patched executable.

## Synthetic preview and experiments

The preview has a separate bundle identity, forces synthetic Pass and Mail data,
refuses sign-in/restore and does not register a menu-bar item or global hotkey.
Its UI cannot start either account helper or open Bridge configuration.
The credential-provider experiment is typechecked only; it is not embedded,
registered or enabled, publishes no identities, and cancels every request. Its
candidate-origin filter is not a production disclosure authorization policy.
See docs/CREDENTIAL_PROVIDER.md and docs/OFFLINE_DESIGN.md for unresolved gates.

## Release requirements

A production release needs independent review, disposable-account interoperability
and recovery tests, session expiry/revocation tests, signed/notarized bundles,
corresponding-source dependency notices, and measured performance against the
same workloads in official clients. Native autofill, passkeys/security-key login,
multiple accounts, and offline locking are separate security-sensitive features.
Local signing is configurable without relaxing Keychain ACLs. Stable local
signatures alone have not passed prompt-free rebuild continuity on this host;
see docs/LOCAL_SIGNING.md. Never delete session keys to avoid authorization.

## Developer account validation

`ProtonXValidation` is a separate opt-in developer tool, not part of the app bundle.
Its native form stores only a designated test-account username/password in local,
non-synchronizing Keychain service `org.kevb.ProtonX.Testing`. It never prints them.
Validation reads that item in-process, uses the private challenge pipe, and removes
the temporary Keychain item after the attempt, including failure. The encrypted
ProtonX session can remain for UI testing. Synthetic records may remain in Trash;
the tool never purges them, sends mail, or changes account subscriptions/passwords.
Do not run it against a primary vault. Passwords are not accepted through argv,
environment variables, repository files or a chat message.
