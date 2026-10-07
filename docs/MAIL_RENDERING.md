# Native Mail message rendering

HTML-to-text conversion previously exposed ASCII table rules, markdown-like
heading/link markers and lost newsletter layout. Native Mail now keeps the
selected message's HTML structure. This is a general MIME-based path, not a
special case for Proton notifications or any sender/domain.

The existing pinned `mail-html-transformer` performs whitelist and CSS sanitation,
disables remote and embedded content, adds link referrer protection and retains
style sheets in the returned body. The helper restores validated HTTP(S) image
addresses only as inert attributes, with credential-bearing and embedded URLs
excluded. The helper sends `sanitizedHTML` alongside its
text fallback over private IPC. Plain-text MIME is never interpreted as markup.
Both representations are limited to 2 MiB; HTML is limited to depth 128 and 50,000
nodes before recursive serialization. Unsupported MIME fails explicitly.

SwiftUI/AppKit continues to own navigation, account access and composition. Only
the selected HTML body uses macOS WebKit; no web product UI is embedded. A fresh
nonpersistent view loads an in-memory document, with no file base URL or account
credentials. Content JavaScript is disabled, CSP denies resources except inline
styles, and a compiled resource rule list must succeed before any body loads.
The default policy blocks all resources; image opt-in admits only the dedicated
native image scheme.
Frames, forms, media, popups, downloads and automatic navigation are refused.
The whitelist is the first boundary; these WebKit rules are independent defenses.

The shell follows macOS appearance; message paper uses light appearance while
retaining sender styles. Trusted constant code in an isolated client content world
measures body height on load, width changes and later layout/image growth. Vertical
wheel/trackpad gestures over a full-height body route to the outer message scroll
view. Height is bounded to 50,000 points; exceptionally tall content retains its
own WebKit overflow scrolling. This preserves text selection, links and horizontal
scrolling while making the whole message reachable.

**Load images** enables external raster images for the selected message only.
**Block images** recreates the blocked reader; changing message, closing or locking
also discards the choice. The tooltip explains that direct requests can reveal IP
and open activity to the sender. This is not Proton's image proxy. A fresh,
nonpersistent native downloader supplies image bytes through a private WebKit
scheme. It has no cookies, referrer, credential storage or disk cache; permits
only HTTP(S), retains standard TLS validation and rejects HTTPS downgrades.
Raster MIME types, 4 MiB per-image bounds, a conservative 16 MiB message budget,
64-request limit and transport timeouts bound the operation. Discarding the view
cancels downloads. Embedded/CID/SVG images, CSS backgrounds, external styles/fonts,
frames and scripts stay blocked. No sender-wide preference is saved.

Trusted constant code in the isolated client world activates only inert image
attributes and reports numeric layout heights through a dedicated weak handler.
It has no account/helper bridge. Content JavaScript remains disabled throughout.

HTTP(S)/mailto links require confirmation showing the destination, then open
through macOS. Other schemes, credential-bearing URLs and automatic opens are
refused. Link labels are sender-controlled; the confirmation does not certify the
destination. The Plain text control offers a fallback, which can still contain
conversion markers. WebKit failure returns to text. Lock/selection changes clear
the body and remove the old view; they do not promise process-memory scrubbing.

Bridge remains a separate plain-text compatibility reader. The native helper and
Swift field are additive; old text-only responses still decode without markup.
Drafts/reply signatures and sending remain handled by Proton's existing core.

Synthetic contracts cover styled newsletters, tables, headings, lists, quotes,
entities, malformed HTML, literal plaintext, dangerous tags/attributes/URLs,
image/CSS disabling, bounds, old IPC compatibility and lock/late-result handling.
Native WebKit tests also verify actual structure, disabled message scripts, light
paper, content replacement and zero requests by default to a disposable local
endpoint. An in-process synthetic image transport exercises real scheme/image
loading, cookie/referrer exclusion, per-message reset, rejected active/oversized
responses and cancellation. Native scrolling and late layout growth have contracts.

The image-only resource boundary uses WebKit's
[content rule mechanism](https://webkit.org/blog/3476/content-blockers-first-look/);
no ATS exceptions or certificate-validation bypass are added.

## Conversation reader

The toolbar switches between **Conversations** and **Messages**. Loaded folder
summaries group by the SDK conversation ID; matching subjects are never used to
infer membership. Search matches any loaded member, unread styling reflects
loaded members, and list counts do not claim a server-wide conversation total.
Older helpers without conversation IDs retain individual-message browsing.

Opening a row calls the pinned core's conversation API with the selected folder
message as its anchor. The SDK supplies authoritative membership across folders,
including Sent, while keeping its normal Trash visibility. Unique message IDs,
matching conversation identity, the anchor's presence and chronological ordering
are validated on both sides of IPC. Metadata is capped at 200 messages and 4 MiB;
failed or oversized conversations fall back to the selected message with an
explicit error and retry/individual-view choices.

The reader presents chronological cards with native headers. One card is expanded
at a time, and closing it leaves all cards collapsed. Each expanded card gets its
own existing bounded renderer, actions and reply context. Selection and session
generation checks discard late metadata/body responses after switching or locking.
Remote-image consent does not carry between cards. There is no whole-conversation
read/move/delete operation; the selected message remains the unit of mutation.

Synthetic contracts cover cross-folder members, grouping/search, reply and action
targets, fallback, malformed/oversized membership and lock/folder-switch races.
Real-account conversation interoperability remains an acceptance gate. Attachment
viewing/sending and richer conversation navigation remain follow-on work.
