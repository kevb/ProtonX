# Contacts

Contacts is a native view of the selected Proton Mail account's address book.
Choose **Contacts** in the product rail or press **⌘4**. It includes name/email
search, contact groups, email addresses and selected decrypted contact fields.
An email action opens a new Mail composer; an existing draft is retained and
must be used instead of silently replaced. Group addressing visibly adds members
to To. The To/Cc/Bcc pickers let the caller choose the intended disclosure scope.

## Account and data boundary

Contacts belongs to Mail, rather than introducing another Proton product session.
It cannot restore or authenticate an account in the background. **Continue in
Mail** opens the existing Mail sign-in/unlock screen and returns to Contacts after
an explicit successful unlock. Leaving that navigation cancels the return intent.
No Pass or Calendar credentials are read or exported. Mail lock, sign-out, expiry,
screen lock and suite close clear the contacts list, details and search state.

The pinned Mail SDK initializes/synchronizes contacts and handles card decryption
and interpretation. The helper exposes only `contacts` and `contact_detail` reads.
Details require an ID disclosed by the latest successful list in the same helper;
a failed list invalidates that scope. There are no contact write, batch, import,
export, raw-card, remote-ID or arbitrary account commands. Photos, logos and member
URIs in contact cards are neither fetched nor opened.

The list is read from the SDK's local index, bounded to 5,000 entries and 4 MiB.
Groups may include up to 1,000 addresses. A selected detail is bounded to 256 KiB;
the native decoder validates identity and field limits. Refresh/reload re-reads
the local index; it does not prove a new server synchronization. While visible,
Contacts re-reads that index every 15 seconds, using the SDK's existing event sync
rather than adding API polling. Contact details reload on selection/manual refresh.
Empty initial results may reflect ongoing SDK initialization.

Proton's existing Mail database stores contact metadata/card material. Contacts
adds no database, file export, defaults cache, macOS address-book permission or
new Keychain item. Normal Mail storage remains ordinary SQLite as described in
[the storage review](LOCAL_STORAGE.md); the Contacts screen does not resolve that
release blocker. Details live in app memory while Mail is unlocked. Clearing
references does not guarantee memory zeroization.

## Recipient selection

Pickers accept only email strings from the current session's disclosed list and
bind to the current draft token. Existing To/Cc/Bcc values are preserved; addresses
are deduplicated across those fields without moving a Bcc address to To. Malformed
or unfinished existing addresses refuse the addition rather than dropping input.
The native 100-recipient bound and existing SDK sending policy remain in force.
No message is sent by browsing/selecting a contact.

## Validation and remaining work

Synthetic tests cover lock/expiry, delayed list/detail responses, selection races,
draft retention, picker scopes, address bounds and preview isolation. Public SDK
contact list/card tests use local fixtures. Real account reading and cross-client
refresh remain manual acceptance steps. Preview contacts are fictional and never
start an account helper.

Create/edit/delete, field-type labels, group administration, CSV/vCard import and
export, recipient autocomplete, Calendar invitation picking and optional Apple
Contacts integration remain backlog items. No system address-book sync is implied.
