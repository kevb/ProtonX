# Native Mail attachments

Mail attachments use the pinned Proton Mail SDK for download/decryption,
encrypted upload, quota checks, draft attachment jobs and removal. ProtonX adds
native file controls and a bounded, private IPC adapter. No Gmail-specific file
operation or new cryptography is introduced.

## Reader

Expand a message to see its listed attachments, filenames and sizes. The Save
button opens a native file dialog. Preview uses macOS Quick Look for PDF, supported
raster images and TXT/CSV; its Open in app button explicitly opens a temporary
copy in the default application. Other file types can be saved and opened from
Finder. Preview copies are removed on dismissal, selection change or Mail lock.
An external application can retain its own copies independently.

The current native transfer limit is 25 MB per file. Proton's own total-message,
attachment-count and storage limits remain authoritative. Oversized files remain
visible with an explanation; no partial export is published. Inline/CID image
placement in the HTML reader remains a separate feature. Attachment signature
verification indicators are not supplied by this adapter.

## Composer

Choose Attach files or drop files onto the attachment area. Filenames and sizes
appear with Uploading, Waiting for connection, Uploaded or Failed states derived
from the SDK. Remove acts on one attachment belonging to the current draft.
Attachments in existing drafts remain in the SDK's original edit/send path.

Attachment operations preserve unsaved text and recipient edits. Adding or
removing files does not send a message. Send is unavailable while file transfer or
SDK uploads are incomplete; both the UI and helper check readiness. Offline upload
jobs remain with Proton's durable draft queue. ProtonX does not add another queue
or repeat an unconfirmed upload. An uncertain add/remove requires Refresh list
before another attachment change or send. Refresh reconciles attachment metadata
without replacing the local unsaved text.

Cancel stops the app's transfer. A job already handed to Proton's SDK may still
complete; the attachment list must be reconciled before repeating a change. Lock
cancels private IPC, clears preview files and rejects late results. Product-tab
switching retains the Mail draft and its upload jobs independently of Pass.

## File and storage boundaries

The helper accepts no input/output paths from the app. A selected file is read
through a regular-file, no-follow descriptor, then transferred as bounded binary
chunks over private stdin. Download requests recheck a disclosed message in the
current folder/conversation; IDs from another message do not authorize export.
Transfers are single-owner, sequential, limited to one active file and expire
within two minutes. Offsets, sizes and final framing are validated at both ends.
Filenames cannot select paths or inject display controls.

The helper creates a random mode-0600 file in the SDK's draft staging directory
only while the SDK imports an upload; it removes that staging file afterwards.
The SDK performs its existing file import/encryption and account checks. A crash
can leave a staging file; the upstream staging cleaner remains responsible for
recovery. Normal builds retain their documented plaintext SDK cache/database
boundary. The opt-in encrypted-storage candidate reads cache ciphertext through
its existing in-memory decryption path, never treats a ciphertext path as an
export. This feature does not activate or migrate encrypted storage.

User-chosen exports are written atomically with mode 0600 and the macOS download
quarantine attribute. Replacing a destination replaces its directory entry and
does not follow a symlink. Preview directories have mode 0700. Explicit exports
and external-app copies are outside ProtonX's local lock/storage protection.
Crash-leftover preview files may remain in the system temporary directory; cleanup
is not a guarantee of forensic erasure or process-memory zeroization.

## Validation

Synthetic Swift fixtures exercise binary chunk framing, filenames, limits,
preview cleanup, late replies after lock, symlink refusal, private/quarantined
exports and ambiguous upload handling with unsaved text. The SDK export fixture
exercises binary/empty cache data in normal and opt-in encrypted modes. Public
upstream attachment/draft tests cover encryption, upload/remove, send behavior
and quota refusal using local mock servers and public synthetic keys.

Real-account attachment send/receive interoperability and interrupted-upload
recovery remain acceptance steps; synthetic test success is not delivery proof.
