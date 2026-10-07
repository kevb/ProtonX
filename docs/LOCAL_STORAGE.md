# Local storage and startup review

Review date: 2026-10-06. No real account or installed profile was inspected.

## What the empty-first experience means

Pass opens its workspace after local unlock, then asks a newly started helper for
an atomic vault/item/Trash snapshot. Each command bootstraps Proton's event sync;
item lists fall back to server fetching because the Rust item cache is process-local.
The SQLCipher database persists keys, policies and settings, not a complete vault.
See [the Pass offline design](OFFLINE_DESIGN.md).

Mail restores its separate session and opens Proton's local SQLite database.
The SDK's scroller can read saved rows and sync in the background. However, our
`snapshot` command immediately calls `fetch_new` and waits up to five seconds for
callbacks and loading completion before replying. The main window becomes visible
before this snapshot arrives. Thus an initially blank list is not proof that every
record comes from the network, or that there is no local cache.

Both windows now distinguish an initial load, a failed initial load and a confirmed
empty result. Existing content remains visible during an ordinary refresh. This
corrects misleading empty states; it does not shorten network work or add offline
storage. No startup speedup or memory reduction has been measured.

## Mail security correction

The pinned Mail core protects session access/refresh tokens and key secrets using
its Keychain-backed session encryption key. That does **not** encrypt the Mail data
database. `mail-stash` uses ordinary bundled SQLite with no database key in its
connection configuration. Metadata includes subjects and participants; successful
message decryption stores `RawMessageBody` in the `raw_message_body` table as decoded
bytes. Disabling content search does not disable this body storage.

The synthetic `protonx_local_storage` contract writes a public fixture and a synthetic
decoded body into a temporary SDK database. An ordinary SQLite connection can read
that body without a Keychain key, and the file has an ordinary SQLite header. This
test documents the current baseline; plaintext storage is not a desired contract
to preserve when encrypted storage is implemented. Never use it on a real profile.

Local unlock/lock controls disclosure in the app, not encryption of those disk
files. FileVault, when enabled, protects a powered-off/locked volume under macOS's
own policy; it is not a replacement for product-specific cache encryption. No
existing account database was deleted, migrated, opened for inspection or modified
by this review. Avoid describing this alpha as a secure local Mail cache.

## Opt-in encrypted-storage candidate

The default app remains on the baseline described above. This candidate is **not
installed or enabled for existing accounts**. `scripts/build-mail-helper.sh
--secure-storage` writes a separate helper to `.tools/mail-helper-secure`; normal
app builds continue to package `.tools/mail-helper`. Do not substitute the candidate
into an account build while migration and attachment gates remain unresolved.

The candidate configures SQLCipher on every SDK read/write connection before its
first statement. A random 256-bit database key is kept in the separate local
Keychain service `org.kevb.ProtonX.Mail.Storage`, account `database-v1`. Account and
user databases share this Mail-only storage key; Proton account cryptography,
product policy, Pass keys and Mail session keys remain unchanged. Keys travel
through an in-process C API; they are not printed or passed in argv/environment.

Before SDK initialization, the candidate takes a profile lock, rejects symlinks,
checks all session/user database headers and validates encrypted files. A missing
key for existing databases, a wrong key or damaged data fails closed rather than
letting the SDK rebuild a profile. Any existing plaintext database is refused
**before Keychain access**. There is no user migration action yet. New databases
are keyed before schema creation. Database workers are joined on graceful pool
shutdown to close encrypted connections before process/crypto-library teardown.
Both updated helper variants now hold the profile lock. They refuse a pending
migration before SDK/Keychain access; the normal helper also refuses encrypted
profiles. Historically older builds still do not honor this lock or these gates.

`Tools/MailStorage` contains a low-level, synthetic-tested single-file export:
checkpoint WAL, export with SQLCipher into a same-directory temporary file,
preserve schema/application versions, verify, sync and atomically replace. It is
not called by the helper. It does not yet provide a whole-profile transaction,
crash recovery manifest, old-build exclusion, backup handling or secure erasure.
The generic pending-send fixture demonstrates row preservation, not SDK queue
replay or delivery safety. Never invoke it on a real profile yet.

A separate resumable database-set staging coordinator now prepares encrypted
copies of every discovered account/user database under a private migration
directory, retaining originals. It binds the plan to the original key, verifies
source/WAL fingerprints and acknowledged outputs, and resumes tested process-crash
points. Both updated helpers refuse that profile even when preparation completes.
The pinned SDK schema/body fixture also preserves draft references and opaque
queue bytes without executing the queue. This is not whole-profile activation,
attachment conversion, actual send recovery or secure removal of old plaintext.
See [the migration boundary](MAIL_STORAGE_MIGRATION.md).

The candidate advertises `cacheFirst` after authentication. Swift requests a local
first page, then one refresh. Subsequent `poll` requests read callback status
without queuing another fetch. Saved content retains selection/body during refresh
and failure; only a successful network-refresh status updates `lastSynced`.
Legacy requests and normal app behavior remain supported. Synthetic store tests
cover that command sequence, stale refresh labels, failure retention and lock
cancellation. An encrypted actual-SDK fixture reads its decoded body locally and
reopens with the key, without a server. Offline session restoration and measured
startup latency have not yet been established. Preflight currently runs full
cipher integrity checks over the databases; their cost on large mailboxes must
be measured and addressed before activation. The shorter snapshot wait alone
does not establish a faster launch.

**File caches are still a release blocker.** The SDK also writes decrypted
attachments/embedded MIME attachments into ordinary files outside SQLite.
SQLCipher does not protect those files, backups or old plaintext profiles. No
complete secure Mail cache claim follows from encrypted database tests. Pass's
complete persisted item cache is also still separate future work.

Run `scripts/test-mail-storage.sh` for the temporary synthetic engine/SDK tests and
secure-helper contracts. They never request Keychain credentials or open an
installed account profile. SQLCipher's documented
[export-based conversion](https://www.zetetic.net/sqlcipher/encrypting-plaintext-databases/)
and [key API](https://www.zetetic.net/sqlcipher/sqlcipher-api/) underpin this candidate.

## Remaining implementation sequence

1. **Finish protection beyond the encrypted database candidate.** SQLCipher
   connection initialization and separate Mail storage keys are implemented behind
   the opt-in feature. Protect attachment/embedded-MIME file caches through an
   established encryption layer, preserving SDK read/write semantics. Do not create
   a decrypted Swift-side cache or call the whole profile secure yet.
2. **Complete migration cutover and recovery before enabling it.** Resumable
   database-set staging is implemented and keeps originals. Whole-profile cutover
   and its native recovery workflow must make conversion explicit and recoverable.
   An encrypted new file is insufficient
   if old plaintext copies or journals remain. Never erase a saved draft/send queue
   or delete a session key as a shortcut. Missing keys, damaged files and unknown
   schemas must fail closed with a useful recovery path.
3. **Return Mail's saved first page after local unlock**, then request network
   refresh. Use separate read/status commands so polling never starts duplicate
   refreshes. Keep selection and scrolling stable; clearly label saved content,
   refreshing, refresh failure and actual successful refresh. Don't use the time
   of a local database read as a server-sync timestamp.
4. **Persist Pass's encrypted item revisions through Proton's crypto/storage
   layer.** Store account ownership, revision/key rotation and validated capabilities;
   preserve product entitlement and organisation policy. Begin with read-only
   cached browsing, not an offline write queue. Keep Pass and Mail keys separate.
5. **Measure synthetic startup and refresh workloads.** Record time to first list,
   helper startup, local read, network refresh and selected-detail disclosure for
   cold/warm launches and large datasets. Log timings/counts only, never content,
   account addresses or raw helper output. Use matching workloads for comparisons.

Acceptance coverage: restart with a disconnected synthetic server; valid, missing
and wrong keys; tampered/truncated storage; plaintext absence in files/journals;
account separation; schema upgrade; lock during decrypt; expired/revoked sessions;
failed refresh retaining the last list; policy/plan changes; interrupted migration;
pending drafts and ambiguous sends surviving upgrade without duplicate delivery.
Public mock-server tests establish source behavior, not real-account interoperability.

## Source anchors

These are paths in the pinned repositories recorded in `upstream.lock.json`:

- Pass: `pass-cli/src/main.rs`, `pass-cli/src/features/mod.rs`,
  `pass/src/item/list.rs`, `pass/src/cache.rs`, `pass-db/src/models/`.
- Mail: `project/mail/rust/shared/stash/src/stash.rs` and
  `connection_manager.rs`; `shared/sqlite3/Cargo.toml`;
  `core/core-common/src/context.rs`, `auth_store.rs`, `user_context.rs`;
  `mail/mail-common/src/models/message/message_body.rs`, `datatypes.rs`,
  `mail_scroller.rs`, `mail_scroller/source/data_scroller_source.rs`.
- ProtonX: `Tools/ProtonXMailHelper/src/main.rs` (`snapshot`),
  `Tools/MailContractTests/local_storage.rs`, both native stores and list views.

## Candidate attachment cache progress (2026-10-06)

New attachment/embedded MIME writes in the opt-in candidate now use SQLCipher
containers through a pinned SDK adapter, with in-memory reads/copies and generic
filenames. Synthetic genuine-SDK store/cache-hit/copy tests pass alongside
wrong-key, corruption and plaintext-absence checks. Startup rejects legacy cache
layouts/links before Keychain and verifies new containers before SDK startup;
remaining cache data also prevents replacement key creation. Those checks add
unmeasured startup work. Existing cache conversion/rebasing, export/staging/file
API audit, whole-profile cutover and queued-send recovery remain gates. The normal
app remains on its documented plaintext database/cache implementation. See
[the migration boundary](MAIL_STORAGE_MIGRATION.md).

Pass's read-only encrypted saved vault is now implemented and synthetic-tested;
its older "future cache" discussion above is superseded by
[OFFLINE_DESIGN.md](OFFLINE_DESIGN.md). Real disconnected restart and update
Keychain continuity still need manual account acceptance.
