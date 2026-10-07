# Mail workflow and suite launchers

## Available behavior

Mail's selected-message header provides **Mark as Read/Unread**, **Archive**,
**Move to Trash**, and **Move to Inbox** when Proton offers those actions. Move to
Inbox is the recovery action for a trashed message; it does not claim to recover
an arbitrary previous folder. A move exposes **Undo move** for 30 seconds using
Proton's one-use undo object. Queue acknowledgements are labelled "queued for
sync"; they are not a server-delivery confirmation. An uncertain change needs a
refresh before another action, and ProtonX never repeats it automatically.

The helper accepts one message ID from the current bounded list, resolves only
SDK-offered destinations, and excludes permanent deletion/bulk actions. The UI
keeps the selected body on failure and clears actions/undo on lock. Narrow reader
columns put organisation and reply controls on separate rows.

Both windows have a visible **ProtonX** product switcher. Opening a product brings
its existing window forward; it keeps its own session. **⌘1** opens Pass and **⌘2**
opens Mail. New (**⌘N**), Search (**⌘F**) and Refresh (**⌘R**) follow the front window.
Mail also uses **⇧⌘U** for read/unread, **⌘E** for archive and **⌘Delete** for Trash.
The default text-field Undo remains available; moving mail has an explicit Undo
button. The suite still owns one optional menu-bar item and one Dock/⌘Tab identity.

## Build and install on a development Mac

Build the normal helper and app, then install with the two native launchers:

```sh
scripts/build-app.sh --stage-update="ProtonX Daily Use Update" --install
```

When helpers already match the current source, `--skip-helper` avoids rebuilding
them. It must not be used to package old helper commands with new UI source.

This installs **ProtonX.app**, **ProtonX Mail.app** and **ProtonX Pass.app** in
`/Applications` and registers them with Launch Services. Spotlight indexing may
take time. The two launchers only select the right window in the shared app. They
exit after handing over and add no persistent process, account state or menu-bar
icon. Existing product windows remain open. Quit any running development copy
before launching the installed app; the launcher explains this if necessary.

For a user-owned install directory, call the installer directly with
`--destination "$HOME/Applications"`. All three bundles must be adjacent.
Generated launcher bundles stay in `.tools/product-launchers` so the installed
Applications copies are the discoverable launchers.

The installer verifies all source and destination identities/signatures before
publishing, refuses a running installed app/helper, and uses macOS same-volume
atomic directory swaps. Previous bundles remain under the hidden
`.ProtonX Previous Builds` directory. Interrupted staging is also retained for
recovery. Those folders contain app binaries only; account profiles and Keychain
entries are never changed. Older saved bundles may be removed after accepting the
new build. Local signing is preserved; Developer ID/notarization and reliable
Keychain prompt continuity are still separate release gates.

## Synthetic validation and remaining acceptance

- Native contracts: one selected ID, capability refusal, uncertain-result blocking,
  SDK undo token, lock/late-result races, closed/bounded IPC and product URL parsing.
- Genuine upstream mock-server tests: message read/unread, moves and local/remote
  undo; normal attachment I/O compatibility; existing composer/reader tests.
- Installer tests: atomic swap, rollback, first install and failure retention with
  disposable synthetic directory contents. Native launchers compile and signatures
  are verified; account-capable installed navigation remains a separate acceptance check.
- Synthetic preview: product switching, front-window keyboard commands and
  Trash/Inbox/undo, with no helper or account access.

Mail encryption remains an **opt-in candidate**. New attachment/MIME cache writes
are now protected alongside candidate databases; existing-profile cutover,
cache/path migration, pending SDK sends and a full file API audit remain gates.
The installed normal app still has the plaintext Mail database boundary documented
in [SECURITY.md](../SECURITY.md). No automatic conversion of your account is run.

Pass's encrypted saved vault already has automated synthetic close/reopen,
network-failure and reconnect coverage. The remaining real disconnected
restart/Keychain-update acceptance is in [OFFLINE_DESIGN.md](OFFLINE_DESIGN.md).
Automation must use fixtures rather than disconnecting a development Mac or reading real
vault entries.
