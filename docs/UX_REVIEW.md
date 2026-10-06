# macOS UX review

Review date: 2026-10-05. Source-backed review of the pinned desktop/native clients,
not a usability study or an account-based walkthrough of official installed apps.

| Area | Observation / tension | ProtonX response |
| --- | --- | --- |
| Menu-bar slots | Separate product identities can duplicate persistent controls in a narrow menu bar | One optional suite item with direct product actions; users can remove it |
| Product separation | Mail and a password vault have different tasks and lock lifetimes | Separate native windows and sessions; shared app commands, preferences and lock action |
| Login | Desktop web/browser handoffs interrupt the app's context | Proton's desktop account handoff in macOS authentication services; direct native fields remain experimental after a server rejection; Mail uses Bridge |
| Sign-in failures | A generic failure cannot distinguish credentials, networking and product eligibility | Fixed failure categories and numeric HTTP/API codes; no raw server messages or account identifiers |
| Keychain | Session ownership and local encryption must be deliberate | Dedicated Pass Keychain namespace and encrypted profile; separate Mail credentials; no account password in preferences |
| Clipboard | Copies may persist or sync; a timer must not erase the user's next unrelated copy | Concealed/transient pasteboard markers and a 30-second change-count lease; lock clears owned copy only |
| Windows | Electron windows can miss expected native sizing, toolbars and keyboard behavior | SwiftUI split views, standard resizing/toolbar/search, Window menu and product shortcuts |
| Resource usage | Shipping native UI doesn't establish an end-to-end memory win | On-demand helpers and measurements; Mail's Bridge cost included in future comparisons |
| Secret visibility | Bulk payloads and selection races can expose more decrypted data than needed | Metadata lists, selected-item details, concealed fields, cancel and epoch guards on lock |
| Lock behavior | Global lock is useful; every focus change would make mail/vault switching frustrating | Sleep, screen lock, user-switch and inactivity lock; no focus-loss lock |
| Remote message content | Rendering mail can introduce trackers or active content | Native text rendering; no remote image loading; HTML-only state explicit |
| Upstream complexity | Full vault parity includes autofill, passkeys, sharing and recovery | Alpha limitations surfaced in README; no fake buttons for unimplemented services |

## Intentional limitations

No unified cross-product search: vault titles and mail subjects have different
privacy and indexing requirements. No central shared Proton token: sharing account
identity does not mean sharing product encryption keys/session lifetime. No
assumption that hiding the app's menu item saves runtime resources. No automatic
background polling or OS login item in 0.1. Refresh is explicit. Global quick
access is opt-in; registration failure disables it, preserving another app's key.

## Follow-up evaluation

Verify VoiceOver navigation with real users, keyboard-only creation/editing,
long vault/title names, large vault counts, high-contrast appearance, non-Latin
mailboxes, reduced motion, multiple displays, menu-bar overflow, session expiry,
network failures, and blocked account login. Test native autofill/passkey system
extensions before treating Pass as a day-to-day replacement.

## Native UX follow-up, 2026-10-06

The supplied official-app screenshot informed hierarchy and task flow only. Its
account/item contents were not copied into fixtures or assets. Keep familiar
three-column navigation with macOS controls and system appearance.

Native sidebar selection replaces buttons embedded in list rows: the latter
looked active but did not reliably execute collection changes. Selection clearing
now belongs to the store and is covered independently of view updates. The
synthetic GUI check confirmed Notes selection clears an old login detail.

The middle pane now identifies the collection and count, offers name/recently
changed sorting, and distinguishes empty vaults, empty Trash and unmatched search.
Selected details show type and timestamps. Unsupported actions are disabled using
permissions and capabilities. Account actions have a larger hit area.

The editor groups details, sign-in fields, websites, verification setup, custom
fields and notes. Notes are available for new logins; websites are editable on
existing items. Website rows have stable identities for add/remove. Concealed
fields remain secure inputs; existing TOTP setup is never displayed. The form
keeps invalid/failed drafts open. Revision conflicts prevent resubmission until
the user reopens the latest item. Confirmed saves with failed refresh close safely
and report success separately from sync failure.
Navigation retains that warning until the vault refreshes successfully, including
when a confirmed edit or Trash action clears the selected item.

The synthetic preview was exercised through native controls: collection selection,
create with multiple websites and notes, hidden custom field, edit, invalid URL
rejection without draft loss, corrected save, Trash, restore and account menu.
The preview is isolated from accounts, Mail credentials, menu-bar slots and global
shortcut registration. Full VoiceOver, minimum-OS, high-contrast and multi-display
coverage remain follow-ups.

Detail reveal/copy state resets when the selected item revision changes. Copy
feedback identifies the individual row even when custom field labels repeat.

## Visual design pass, 2026-10-06

The Pass workspace now uses adaptive indigo/lavender surfaces, softer rounded
cards, larger item badges and clearer type hierarchy. Credentials share one card;
websites, notes and timestamps have their own quiet groups. Edit is a labelled
pill beside the title; Trash/restore is in the item actions menu with the existing
confirmation. Create has a visible label. The editor and locked screen use the
same palette and shapes. The PX wordmark is an independent native treatment;
no official brand assets, remote fonts or favicons were added.

Native split-view resizing, list selection, search, menus and keyboard commands
remain. Selection follows the user's macOS accent; selected icons retain contrast
on both active and inactive rows. Decorative imagery is hidden from accessibility,
item rows include their type, and copy/reveal/create controls have explicit names.
Card borders strengthen with increased contrast; no motion was added.

Synthetic preview checks cover dark and light appearances, the grouped editor,
keyboard creation, confirmation and Trash/restore. The command
`scripts/build-app.sh --preview-light --skip-helper` builds the isolated light-mode
preview without changing macOS settings. Its compile flag has no effect on
real-account windows. Full VoiceOver and minimum-OS runtime coverage remain follow-ups.

The supplied login/note creation references informed a second editor refinement:
native inputs now sit in the same outlined cards as item details, with a prominent
title and visible focus outline. Password generation is beside its input; secure
notes have a larger writing area, with custom fields below. Type/vault pickers
stay native. Multiline note entry and saved login notes/websites/concealed custom
fields passed synthetic interaction checks. The reference screenshots' background
account/item contents were not copied into project assets or fixtures.

## Direct Mail experience, 2026-10-06

Mail opens to native username/password fields in the suite's adaptive palette.
TOTP and second mailbox password use the same form; saved-session reopen uses
Mac local unlock. Manual ports, generated passwords and certificate import are
confined to the optional Bridge compatibility sheet. Pass stays independently
usable, with one shared menu-bar icon and product-window shortcuts.

The reader has native folder and message selection, searchable loaded metadata,
rounded sender/date details, bounded paging and a text-only message body. Search
or folder changes clear hidden details immediately. Lock clears the window and
stops the Mail core. Unsupported challenges and failed operations are explicit.
Dark and light synthetic controls passed selection, search, empty/return folder
and lock checks; full accessibility and minimum-OS runtime coverage remain gates.
This first direct client cannot compose/reply, manage attachments or threads,
mark read/unread or archive. Those actions follow real sign-in/read/restart proof.
