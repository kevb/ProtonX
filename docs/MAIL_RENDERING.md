# Native Mail message rendering

HTML-to-text conversion previously exposed ASCII table rules, markdown-like
heading/link markers and lost newsletter layout. Native Mail now keeps the
selected message's HTML structure. This is a general MIME-based path, not a
special case for Proton notifications or any sender/domain.

The existing pinned `mail-html-transformer` performs whitelist and CSS sanitation,
disables remote and embedded content, adds link referrer protection and retains
style sheets in the returned body. The helper sends `sanitizedHTML` alongside its
text fallback over private IPC. Plain-text MIME is never interpreted as markup.
Both representations are limited to 2 MiB; HTML is limited to depth 128 and 50,000
nodes before recursive serialization. Unsupported MIME fails explicitly.

SwiftUI/AppKit continues to own navigation, account access and composition. Only
the selected HTML body uses macOS WebKit; no web product UI is embedded. A fresh
nonpersistent view loads an in-memory document, with no file base URL or account
credentials. Content JavaScript is disabled, CSP denies resources except inline
styles, and a compiled block-all content rule must succeed before any body loads.
Frames, forms, media, popups, downloads and automatic navigation are refused.
The whitelist is the first boundary; these WebKit rules are independent defenses.

The shell follows macOS appearance; message paper uses light appearance while
retaining sender styles. Trusted constant code in an isolated client content world
measures body height on load and width changes. Height is bounded to 50,000 points;
very long/wide content can use the body view's own scrolling. Images remain blocked,
including embedded/attachment images; logos may therefore be absent. No automatic
dark conversion, remote-image opt-in, attachment loading or rich composer is added.

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
paper, content replacement and zero requests to a disposable local test endpoint.
