# Encrypted saved Pass vault

Implementation date: 2026-10-06. Read-only saved-first browsing is implemented;
real-account disconnected restart acceptance and startup benchmarks remain pending.

## Storage and upstream decisions

The pinned CLI persists keys/settings in SQLCipher but keeps its item cache in
process memory. ProtonX adds two namespaced tables to that same database, using
its existing local encryption key and Keychain provider. Swift writes no item
cache. No dependency, source pin or cryptographic primitive changed.

The upstream review included the Rust `pass/src/cache.rs`, `item/list.rs` and
`pass-db` schema; the iOS `ItemRepository` stores `SymmetricallyEncryptedItem`
through its local datasource; WebClients' Pass auth/settings code has its own
password-derived offline components. ProtonX retains the server's encrypted item
content rather than adopting a second client implementation or inventing a new
password-derived format. Proton's Rust decrypt/protobuf path opens one selected
record. This is ProtonX-specific persistence, not an interoperable official cache.

An online snapshot fetches every visible vault's revisions once and decrypts them
through the SDK for metadata. A complete successful generation stores:

- Original encrypted item content, revision and key rotation, plus item keys inside
  SQLCipher. Item-key copies and serialization buffers are zeroized on drop.
- Encrypted-at-rest vault/item summaries, permissions and capabilities. Summary IPC
  contains titles/type/membership, not usernames, notes, passwords or TOTP seeds.
- Schema version, account ID, hashed session UID, random generation ID, saved time
  and lease expiry. Account/session/schema/generation mismatch refuses reads.

Replacement is one SQL transaction. Incomplete refreshes cannot publish mixed
items/header. A duplicate insert rolls back to the previous generation. Storage
is bounded to 20,000 records, 128 MiB total, 8 MiB metadata and 2 MiB per record.
Missing keys, wrong keys or corruption never cause key regeneration or a database
reset in this path. Normal server refresh may populate an initially absent cache.

## Entitlement and freshness

[Proton documents offline desktop access for paid users](https://proton.me/support/how-to-use-proton-pass-desktop-app)
(rechecked 2026-10-06). This implementation enables it only for the SDK's personal
`Plus` plan. Free and Business/managed plans stay online-only: the pinned SDK does
not expose every organisation offline-policy field. Unknown plan/schema responses
fail closed. This conservative restriction may exclude otherwise entitled managed
users; adding reviewed policy support is follow-up work. CLI eligibility remains
unchanged and separate from the pinned desktop protocol.

A generation lives for at most **24 hours from its online snapshot**, shortened by
positive subscription/trial end dates. This is a ProtonX freshness bound, not a
claim about the official client's expiry rule. Reads reject expiry and a clock
before the saved timestamp. Local unlock cannot detect remote session, share or
subscription revocation while disconnected. Reconnect rechecks current authority;
authentication, certificate or invalid-response failures discard the saved view
and attempt to invalidate the persisted snapshot in the native snapshot path.
Cleanup failure preserves the original failure category; it never resets keys or
turns the failed refresh into cached success. Only classified
connection failures/process timeouts permit continued saved browsing.

Create/edit/Trash/restore invalidate the persisted generation **before** their
network path, including uncertain outcomes. A successful authoritative refresh
rebuilds it. Nothing is queued or automatically replayed. Logout retains the SDK's
existing remote-logout/local-cleanup semantics. Offline browsing adds no credential
reset or logout substitute.

## Native experience and locking

After deliberate macOS local unlock, a local-only command restores saved metadata
before the online refresh. That command returns before event bootstrap, SDK network
construction and telemetry. A separate local-read gate lets selected cached items
open while an online refresh is slow. SQL transactions and generation checks prevent
mixed results. Online success replaces metadata, permissions and selected details.

The sidebar says **Saved vault · refreshing** or **Saved vault · read only**, shows
the actual last-sync time, and offers **Refresh Online**. An online workspace says
**Encrypted saved vault ready** only when publication succeeded. Cache failure is
visible without treating an online vault as empty.

Saved mode permits searching, selecting and revealing/copying one item. It disables
create/edit/Trash/restore and TOTP generation. Attachments are explicitly unavailable.
No attachment file or plaintext item body is persisted by this feature. The regular
clipboard ownership/30-second expiry policy applies. Swift strings cannot guarantee
zeroization; SQLCipher and UI locking do not defend against malware with the same
macOS user/Keychain access. Pass and Mail storage remain independent.

Lock/sleep/screen lock clears visible data and cancels local/network requests.
The lease timer clears an idle saved workspace at expiry. Session and selection
checks reject late results after lock or reconnect. Same-user clock manipulation
is outside the UI lock boundary; this is not an offline revocation service.

## Evidence and remaining acceptance

Synthetic tests cover SQLCipher close/reopen; encrypted saved-session restoration
without constructing a network client; wrong/missing keys; truncated database and
corrupt selected content; rotation/ciphertext preservation; schema/account/session/
lease mismatch; transactional rollback; write invalidation; unsupported plans;
saved-first ordering, independent selected reads, reconnect permissions, lock and
late-result races. App transport failures are injected, not Mac network changes.

Real-account disconnected restart, Keychain continuity across updates, larger-vault
performance and matched startup measurements remain acceptance gates. No automated
real-account access or deliberate real session/subscription revocation is used.

## Manual account acceptance

1. Quit the old ProtonX bundle and open the new staged update. Unlock while online
   and refresh. Confirm **Encrypted saved vault ready** in the sidebar.
2. With no unsaved draft, disconnect your connection, quit and reopen ProtonX,
   then unlock. Search/select a fictional test item; its reveal/copy should work.
   The sidebar should show saved/read-only state and the prior last-sync time.
3. Confirm create/edit/Trash/restore and verification-code copy are unavailable.
   Lock and confirm the visible item disappears; unlock while disconnected again.
4. Reconnect and click **Refresh Online**. Confirm the saved label disappears and
   the latest test item/permissions are visible. Edits should then work normally.

Do not use a real secret as the test record or delete Keychain entries to test
missing keys. Those failure cases have isolated synthetic coverage.
