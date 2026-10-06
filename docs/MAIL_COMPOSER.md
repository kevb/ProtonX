# Native Mail composer and linked Gmail

Review date: 2026-10-06. The user reported successful native Mail sign-in and
message reading. That is useful interoperability evidence, but does not establish
sending, restart/revocation recovery or linked-Gmail delivery.

## UX references

Proton's desktop shell displays its Mail web client. These official support
screenshots provide public composer references without reading a private inbox:

- [Normal and maximized composer, field hierarchy and plain-text mode](https://proton.me/support/composer)
- [Compose and send](https://proton.me/support/send-messages)
- [Gmail connection versus importing and legacy forwarding](https://proton.me/support/switch-from-gmail-to-proton)
- [Gmail state and folder sync limitations](https://proton.me/support/troubleshooting-easy-switch)

The implementation follows the From → To/Cc/Bcc → Subject → body hierarchy,
visible Send action, saved/unsaved state and reply actions. Native text fields,
a text editor, keyboard shortcuts and a sheet replace the browser composer.
No reference screenshots or account contents are checked in.

Pinned WebClients `applications/mail/src/app/helpers/addresses.ts` filters the
From choices by active/send/receive state and selects a reply address using the
original message's address identity. `messageDraft.ts` carries that AddressID,
ParentID and the reply action into the draft. Proton's pinned Rust core provides
the corresponding draft constructors, signatures, recipient handling and send
queue; ProtonX calls these rather than reconstructing the encrypted protocol.

## Sender policy

A full Gmail connection can send from the connected Gmail address. Importing old
Gmail messages or using legacy forwarding alone does not create that capability.
Only addresses returned by the core are offered in From. New drafts retain the
core's default; replies retain the core's original-address choice. Plus aliases,
Reply-To, reply-all self exclusion and product restrictions remain with Proton.
No Gmail SMTP password, Google OAuth token or separate Gmail session is added.

The sender remains visible in the composer and is named in the Send confirmation.
If the core substitutes an unavailable receiving address, the composer warns
about the change. Disabled/disconnected Gmail addresses fail rather than being
invented or silently substituted by ProtonX. The exact From address should be
verified in the received message during a user-driven linked-Gmail delivery test.

## Implemented behavior

- New message, reply and reply all; open an ordinary selected draft.
- From selection, To/Cc/Bcc, subject and a native plain-text editor.
- New replies preserve the core's original signature and quoted HTML/MIME content;
  it is shown as a text disclosure without loading remote resources. Entered text
  is escaped if the core uses HTML. Reopened drafts use a simplified text edit of
  the complete body; original rich formatting is not retained on save.
- Existing core-managed reply attachments are retained. File upload/removal and
  attachment viewing are not implemented. Scheduled drafts are refused.
- Save Draft and Save & Close explicitly apply the whole validated batch before
  asking the core to save. The opt-in native feature disables the SDK wrapper's
  immediate per-field auto-save; upstream defaults stay unchanged. A successful
  save response means stored locally and queued for sync, not confirmed remote
  persistence. Unsaved editor text can be lost on lock/close; use Save Draft.
- Send queues exactly one core operation for a composer token. Queued, confirmed,
  failed and unknown outcomes are distinct. The app checks the core's stored send
  result for that message before showing success. It does not start another send
  after timeout, cancellation, lock or an uncertain result. The core retains its
  own encrypted action queue and retry/undo-delay behavior.
- Closing a pending composer does not cancel delivery or discard the message.
  Check Sent/Drafts before sending again. Lock is not an undo-send operation.
- Refresh and load-more retain the reader's bounds. Refresh clears a prior
  scroller error so a transient failure can recover. Search remains limited to
  loaded subjects and senders. ⌘N opens a composer; ⇧⌘R refreshes; ⌘Return opens
  the sender/recipient confirmation.

Requests stay on private stdin; no draft text, addresses or errors enter logs,
arguments, environment variables or preferences. The helper validates the
composer token, current selection, sending-address list, recipients and body
size independently. Limits: 100 distinct recipient addresses, 998-byte subject,
32 KiB new text, 64 KiB complete request and 2 MiB signature/quote display.

## Next acceptance tests

Use a designated account and deliberate user sending. Verify a new message,
reply, reply-all and saved draft from another client. Verify received From and
Reply-To for a connected Gmail address, plus disabled/disconnected and legacy
forwarding cases. Exercise network failure, expired sessions, close during send,
server rejection and restart without duplicate delivery. No private mailbox or
real recipient is used by the synthetic test suite.

Next functionality: read/unread, archive/trash with undo, conversation view,
attachment upload/viewing, recipient completion, rich text and confirmed draft
sync/auto-save recovery. Gmail read/unread/folder changes are not mirrored back
to Gmail by Proton's connection; do not promise two-way state synchronization.

## Mail appearance follow-up, 2026-10-06

The sidebar and message list now use a separate Mail palette, with a neutral
sidebar, purple New message action, locally generated sender initials, aligned
dates and clearer folder/header hierarchy. The native three-pane layout remains;
Expand message switches to a wider reader, and Show mailbox restores navigation.

The reader groups From/To/date and reply actions above **white message paper with
fixed dark text**, in both system appearances. The native composer body and Bridge
reader use the same light paper policy. The surrounding shell still follows macOS
appearance. This is a surface/contrast adjustment to the existing plain-text reader,
not HTML recolouring or a new rich-message renderer. Remote images remain unloaded.
No authentication, sender-choice, draft or sending protocol was changed.
