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

One **ProtonX** window has a labelled product rail and a Home screen. **⌘0** opens
Home, **⌘1** selects Pass and **⌘2** selects Mail. Switching products retains
selection, searches, scroll positions and unsaved Mail text. The Mail composer is
nonmodal, so it stays intact while using Pass. Product stores are created on first
use; merely visiting Home does not start a helper or unlock a session.

New (**⌘N**), Search (**⌘F**) and Refresh (**⌘R**) follow the selected product.
Mail also uses **⇧⌘U** for read/unread, **⌘E** for archive and **⌘Delete** for Trash.
Settings select startup behaviour: Home, last product, Pass or Mail. Explicit
Spotlight product launchers override that preference and select the requested
product before activating the suite. There is one optional menu-bar item and one
Dock/⌘Tab identity. Separate/detachable product windows are later work.

Closing the suite window locks both products and discards unsaved Mail text;
**Save & Close** before closing or locking. Switching a rail tab alone does not
lock or send. Screen/inactivity lock and Quit also clear hidden workspace content.

## Build and install on a development Mac

Build the normal helper and app, then install with the two native launchers:

```sh
scripts/build-app.sh --stage-update="ProtonX Daily Use Update" --install
```

When helpers already match the current source, `--skip-helper` avoids rebuilding
them. It must not be used to package old helper commands with new UI source.

This installs **ProtonX.app**, **ProtonX Mail.app** and **ProtonX Pass.app** in
`/Applications` and registers them with Launch Services. Spotlight indexing may
take time. The two launchers only select the requested workspace in the shared window. They
exit after handing over and add no persistent process, account state or menu-bar
icon. Existing product workspace state remains available. Quit any running development copy
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

## Navigation acceptance

Use synthetic preview content for repeatable automated/UI checks. In the installed
app, check navigation without making server mutations:

1. Open ProtonX. First launch shows Home; choose Pass or Mail from a card or rail.
2. Select an item/message, enter a search, switch products and return; the workspace
   should keep its place without another sign-in or loading reset.
3. Start a Mail draft, enter fictional text, switch to Pass/Home and return.
   Confirm the unsaved text remains; save or discard explicitly.
4. Try ⌘0/⌘1/⌘2 and verify ⌘N/⌘F/⌘R target the visible product only.
5. Launch ProtonX Mail/Pass from Spotlight while the suite is open or minimised.
   Each should select its product in the same window. Also test after Quit.
6. Save drafts, lock/close the suite, then reopen; both products must require
   their own local unlock and hidden secrets/unsaved text must not reappear.

Calendar, detachable windows, multiple/minimised composers and autosave are not
part of this navigation build. The existing storage/release gates still apply.

## Touch ID lock screens

Selecting a saved, locked Mail or Pass workspace starts Touch ID directly in the
window when biometric authentication is available. Rest a finger on the sensor;
there is no initial Unlock click. **Use Mac password…** opens the macOS dialog
and can interrupt a pending fingerprint attempt. Without available Touch ID,
the screen offers an explicit password unlock button.

Cancellation leaves the workspace locked with **Try Touch ID again**. An explicit
lock does not immediately restart authentication. Switching away cancels a pending
prompt; selecting that product again starts a fresh attempt. Authentication remains
separate for Mail and Pass. Demo/preview workspaces retain synthetic unlock behavior.

To check the installed build: open ProtonX, choose a locked product, authenticate
with Touch ID, then lock it with ⌘L. Check that it stays locked until retry or a
fresh product selection. Also try password fallback and switching to Home while
the fingerprint prompt is waiting.
