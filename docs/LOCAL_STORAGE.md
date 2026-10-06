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

## Next implementation sequence

1. **Protect Mail's existing database first.** Investigate database encryption
   through an established library, with a separate Mail Keychain key. Cover account
   and user databases, WAL/SHM/journals, draft queues and attachment caches. Compare
   this with field encryption using Proton's existing crypto; do not implement a
   new cryptographic scheme or create a decrypted Swift-side cache.
2. **Design migration and recovery before enabling it.** Make any existing-file
   conversion explicit, atomic and recoverable. An encrypted new file is insufficient
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
