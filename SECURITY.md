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
  do not honor these guards. The opt-in candidate now encrypts newly cached
  attachment/embedded-MIME payloads in atomic SQLCipher blob containers and reads
  them into memory, including SDK cache hits, cloning and calendar invite parsing.
  The original filename stays in encrypted metadata; the cache filename is generic.
  The native attachment export reads bounded cache bytes in memory through the SDK adapter; explicit save/preview produces a user-authorized plaintext file. Internal SDK attachment paths in this
  candidate point to ciphertext, not files another app can open directly. Existing
  cache activation/path rebasing, full file-path/export/staging audit, whole-profile cutover and
  actual draft/send recovery remain release gates. See docs/MAIL_STORAGE_MIGRATION.md.
  Synthetic-only attachment migration staging encrypts copies of existing files
  and the source-path map; it retains originals and does not update SDK references
  or activate the profile. Normal builds never invoke it.
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
- Local unlock embeds Apple’s `LAAuthenticationView` with a per-product
  `LAContext.deviceOwnerAuthenticationWithBiometrics` for Touch ID. One automatic
  attempt requires a visible locked product, its attached native view and an active
  key window. No biometric data is available to ProtonX. Password fallback uses a
  separate context and the standard `deviceOwnerAuthentication` dialog. Cancellation
  or explicit lock disarms automatic retries; choosing a product again or reopening
  the window may arm a new attempt. Switching products cancels pending authentication;
  epochs reject late success before helper access. Products retain separate gates.
  Preview/demo workspaces never evaluate real authentication.
  A UI lock doesn't revoke the remote session or defend against malware
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
- Pass saved-first/offline browsing persists original encrypted revisions and item
  keys/metadata only inside the existing Keychain-backed SQLCipher database. Local
  reads bind to account/session, schema, generation and a maximum 24-hour lease,
  shortened by known subscription/trial expiry. Only personal paid Plus accounts
  are enabled; managed/unknown policies stay online-only. Saved mode is read-only,
  decrypts one selected record and omits attachments/TOTP generation. Writes
  invalidate the generation before network access. No replay queue exists. Local
  unlock cannot detect server revocation while disconnected. Authentication/TLS/
  invalid-data errors fail closed; missing keys/corruption never reset credentials.
  Expiry/lock clears the visible workspace and owned clipboard. See
  docs/OFFLINE_DESIGN.md for exact scope and remaining account acceptance.
- Pass session invalidation clears the visible workspace and returns to sign-in
  across snapshot, detail and write paths, including post-write refresh.
  The UI adds no saved-file deletion; Proton's existing invalidation/cleanup path
  remains responsible for SDK session files. The in-memory invalidation flag does
  not prove a session valid after restart. Saved-session opening requires macOS
  local unlock
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
  1,000-message window limit and 2 MiB rendered-body limit. Selected conversation
  metadata is bounded to 200 messages and 4 MiB, with unique IDs and matching
  SDK conversation identity. No raw SDK errors,
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
  to 998 bytes without control characters. Editor text belongs to a Mail-session
  model and stays in memory across product switches; it is never persisted in preferences. Save explicitly before lock;
  lock, sign-out, draft close and suite-window close release unsaved editor state.
- Native Mail preserves HTML structure using Proton's pinned whitelist/CSS
  sanitizer in the helper, with depth/node/output bounds and a text fallback.
  The selected sanitized body is displayed in an ephemeral local WKWebView, with
  content JavaScript disabled, a deny-by-default CSP and compiled resource rules
  installed before loading. No file base URL, account session or helper API is
  provided. Remote images start blocked. A per-message Load images action enables
  only inert, credential-free HTTP(S) image addresses preserved by the helper.
  WebKit still has no general HTTP access: a dedicated image scheme uses an
  ephemeral native downloader with no cookies, credential storage, referrer or
  disk cache. It accepts only supported raster image MIME types, limits each image
  to 4 MiB, conservatively caps a message at 16 MiB/64 requests, keeps TLS validation
  and refuses HTTPS-to-HTTP redirects. Blocking images, changing selection or locking
  cancels those downloads. Consent is not saved across messages/reopen. Requests go
  directly to the image host (not Proton's proxy) and can reveal IP/open activity;
  the control explains this in its tooltip. Frames/forms/media, CSS images/imports
  and embedded images remain disabled. Navigation is refused except for the app's in-memory
  document; allowed HTTP(S)/mailto links require a user-confirmed external open.
  The reader uses fixed light paper; it does not attempt automatic dark recolouring.
  Trusted constant layout/image activation code runs only in WebKit's isolated
  client content world. Its only script-message handler accepts bounded numeric
  layout heights; it cannot access accounts or invoke helper commands.
  Lock/selection change destroys the selected view and rejects late body results;
  this is not a WebKit process-memory zeroization guarantee. The SDK owns MIME
  and decryption. Bridge retains its limited bounded-recursion plain-text MIME
  reader. Native attachment save/preview and draft upload/removal use the SDK through bounded private transfers; see docs/MAIL_ATTACHMENTS.md. Inline/CID rendering remains disabled. See docs/MAIL_RENDERING.md.
- No telemetry is added. Upstream Pass telemetry is disabled. Upstream automatic
  update checks are skipped by the patched helper in native mode. No auto-updater
  silently replaces this patched executable.

## Synthetic preview and experiments

The preview has a separate bundle identity, forces synthetic Pass, Mail and Calendar data,
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
signatures from a self-signed certificate failed prompt-free rebuild continuity
on this host. An Apple Development identity passed the isolated synthetic probe;
existing product-key authorization and certificate renewal remain separate
validation steps. See docs/LOCAL_SIGNING.md. Never delete session keys to avoid
authorization.

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

## Mail inbox actions and launchers

Reader actions target one selected, previously disclosed local message ID. The helper
accepts conversation requests only from an anchor in the current folder snapshot,
derives the conversation ID itself and preserves the SDK's Trash visibility rules.
A disclosed child from that selected conversation can be read, replied to or
changed only while its matching anchor remains in the current folder snapshot.
Changing folder or signing out clears this scope; a failed conversation switch
cannot retain the previous scope. The UI decrypts one body at a time and clears
its remote-image consent on message changes. The helper
rechecks Proton's action capabilities and local destination IDs before queueing
read/unread or a move to Archive, Trash, Spam or Inbox. List context actions target
one disclosed conversation through the SDK's conversation operations; Messages
view targets one message. Menu choices follow the SDK's stable folder kind and
the official client's folder policy, but the helper independently checks current
capabilities and destinations. Delete/Backspace in the list requires an explicit
whole-conversation Trash confirmation. The helper derives the identity from the
current folder row and checks the caller's expected identity. No arbitrary
conversation IDs, arrays of targets, destinations or permanent-delete flags are
accepted. Intent tickets bind to session, folder, selection and view mode; stale
confirmations cannot dispatch. Reader-card actions remain single-message scoped.
Spam uses the pinned SDK's default move policy. No separate block-sender,
unsubscribe or Google operation is issued; this does not override Proton's
server-side filtering behavior. Linked Gmail messages use the same Proton action
queue as other mail.
Permanent deletion and multi-selection changes are absent. Queue acknowledgement
is not proof of completed server sync. Ambiguous
results block another app action until refresh; no app-level retry or replay is
added. Proton's durable action queue may still finish after lock/restore. Move undo
uses the SDK's original one-use undo object, with a 30-second native lifetime. Lock
clears capabilities and undo state; generation checks reject late replies.

Product URLs accept only `protonx://mail`, `protonx://pass` and `protonx://calendar` without credentials,
paths, query data or fragments. Launchers have no helper, account store or Keychain
access. They open the adjacent installed ProtonX bundle and refuse to route to an
older development copy that is still running. The local installer verifies bundle
identities/signatures, refuses running installed binaries, swaps directories
atomically and retains previous bundles. It does not change Keychain ACLs, session
keys or account profiles; stable local signing does not guarantee prompt-free
Keychain access or notarization.

## Suite workspace navigation

One native window hosts lazy Pass, Mail and Calendar workspaces. A product switch keeps
selection, search, scroll and unsaved Mail editor state in the existing product
objects; it does not unlock, restore or merge sessions. Shared defaults contain
only startup/last-product navigation preferences. Home does not start product
helpers, and the preview ignores real startup preferences. The product rail
excludes hidden content from input/accessibility and uses selected-product
capabilities for commands. Mail authentication-field values clear on switching
away. Suite-window close, screen/inactivity lock and Quit lock all products,
including hidden ones; late helper replies remain subject to existing epochs.
Public product links still accept only the three closed routes defined above and
select the product before activating the same suite window. No account data is
accepted in routes, and no global account/session cache is introduced.

## Desktop notifications

Mail notification monitoring is opt-in and runs only in the unlocked Mail session.
A bounded, nonpersistent queue observes committed SDK CREATE events; no new
push service, device token, secret store, account sharing or transport is added.
The Swift adapter reads this queue over the existing private helper pipe. It
never derives incoming alerts from list diffs, paging, read/unread changes or
message bodies. Screen lock, window close, logout and session expiry stop the
helper and clear pending/delivered app alerts and the unread Dock count.

Private previews are the default. Enabling sender/subject previews explicitly
shares that metadata with macOS Notification Center, whose OS display, Focus
and preview settings also apply. Clearing alerts is not a promise to erase OS
logs, screenshots or notification history after a crash. No message body,
recipient, account identity or session token enters notification content or
routing metadata. OS click routing uses bounded, random in-memory tickets,
invalidated on lock and policy changes. Stale tickets only open the Mail interface, with its usual local authentication
requirements. Valid clicks navigate only to messages disclosed by the current bounded SDK
list and preserve an open composer. Test alerts contain synthetic text only;
preview builds cannot request OS permission, deliver alerts or set a Dock badge.

## Native Mail attachment files

The helper never accepts app-supplied file paths. One transfer is scoped to a
disclosed message or editing draft, with a 25 MB cap, bounded chunks, sequential
offsets, one-use completion and expiry. SDK download/decryption/upload and server
limits remain unchanged. Unknown attachment IDs cannot export another message's
data. Source files are chosen explicitly and opened as regular files without
following symlinks. A mode-0600, random SDK staging file is used only during import;
crash leftovers fall under the existing SDK staging cleaner.

Save/Quick Look/Open explicitly export plaintext outside the cache protection.
Saved/preview files use mode 0600 and macOS quarantine; preview directories are
mode 0700 and removed on normal dismissal/selection change/lock. Crash leftovers
and external-app copies can remain. No forensic-erasure claim is made. Only PDF,
raster images and TXT/CSV are offered in-app preview/open; other types use explicit
Save. Unsaved composer text is preserved during file operations, and uncertain
upload/removal requires metadata reconciliation before repeating a change/send.
See docs/MAIL_ATTACHMENTS.md for complete behavior and acceptance limits.

## Calendar preview

Calendar currently uses synthetic, memory-only events behind a separate typed
data-source boundary. It performs no network, Keychain, EventKit, file-storage or
notification operations. Locks clear events, filters, selected-event details and
editors, including hidden Calendar state. Epoch checks reject late snapshots and
mutation completions; delete intents also bind the disclosed revision and epoch.
Shared navigation preferences contain no event contents. No Mail/Pass credentials
or sessions are used by Calendar. Account authentication, encrypted persistence
and Proton cryptography need independent review before enabling a live backend.
