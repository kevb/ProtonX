# Offline Pass design boundary

Review date: 2026-10-06. Durable offline access is not implemented.

The pinned CLI's SQLCipher database stores share/folder keys, organisation policy,
core event cursors and settings. Its item/vault caches in the Rust client are
process-local. `list_items` falls back to `fetch_items`; a new helper does not
have a persisted complete item snapshot. Skipping network errors at bootstrap
would therefore not create a working offline vault. This corrects the broader
“encrypted cache exists” description in the initial gap analysis.

Source anchors: `pass-cli/src/features/mod.rs`, `pass-db/src/models`,
`pass/src/cache.rs`, `pass/src/item/list.rs`, `pass/src/vault/list.rs` and
`pass/src/core_events.rs` in the pinned Pass checkout.

Proton documents offline desktop access for paid users in its
[desktop guide](https://proton.me/support/how-to-use-proton-pass-desktop-app).
A future ProtonX implementation must preserve that product limit and organisation
policy; it must not infer entitlement from a saved session or a successful decrypt.

## Current failure behaviour

A failed refresh keeps the last successfully loaded in-memory metadata. The app
shows the failure and last successful refresh time; writes remain disabled until
refresh succeeds. Previously loaded selected details may remain visible while
unlocked. Opening other details still requires the helper and can fail. Lock
clears both metadata and selected secrets. This is an interruption state within
one unlocked session, not durable offline support or a complete cached vault.

A save acknowledged by Proton followed by a failed refresh closes the editor
and reports that the item was saved. It disables further writes until a successful
refresh. A failed/unconfirmed save retains the draft and offers refresh before
retrying; it does not automatically retry or queue a second create.

## Read-only offline milestone

Reuse Proton's persisted encrypted representation or add storage through its
existing crypto layer. Do not serialize decrypted `ItemDetail` into a Swift cache.
Review the existing Proton iOS/desktop persistence formats before choosing a new
schema. Required stored data includes encrypted item revisions and key rotations,
vault metadata, an authenticated capability/policy snapshot, freshness timestamps
and account-specific ownership. Corruption, unknown schema or missing keys must
fail closed. Keep Pass storage independent of Mail.

Define offline entitlement expiry/downgrade/revocation behaviour explicitly; offline
clients cannot discover a server revocation without reconnecting. Local unlock is
not revocation. Unlock/decrypt stays behind a deliberate user-presence policy, and
screen lock/sleep/account change clears in-memory secrets. Opening or copying one
item must not decrypt the complete vault into the UI.

First ship read-only access with a visible last-sync timestamp and an offline
indicator. Disable create/edit/trash/sharing and all network-required operations.
Do not add a write queue until revision conflicts, idempotency, acknowledgements
and recovery have independent tests.

Acceptance tests must include restart with networking disabled, permitted/denied
plans, expired policy, missing Keychain key, tampered/truncated cache, rotation,
corrupt revisions, lock during decrypt and account separation. Use synthetic data
and a designated disposable account for interoperability. This needs more than
reusing the current SQLCipher key store.
