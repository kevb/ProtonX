# Native Mail search

Typing in the Mail search field filters subjects/senders on the loaded page.
Press **Return** or choose **Search all mail** to run Proton's account-wide metadata
search. This can find old/imported messages outside the recent folder page and
matches participants as well as subjects. Results are paged through the pinned
SDK, with **Load more** when the SDK reports another page and a native cap of
1,000 displayed messages. Refresh/Search again starts a new search.

Search scope follows Proton's existing All Mail policy; Spam/Trash inclusion
is controlled by its account settings. The app adds no include-Trash override,
arbitrary folder/account/host query or raw database scanner. Body search is
currently disabled in the Mail SDK configuration. Body text, attachment names and
attachment contents are not searched. Advanced date/address/attachment controls
and opt-in local body indexing remain on the roadmap.

Clearing or editing a completed search returns to the previous folder. Choosing
another folder ends search scope. Results are not filtered again using only
visible subject/sender fields, because the SDK may match a recipient instead.
Search controls are disabled during an active query; session lock/expiry rejects
late replies and clears query/results. Product switches preserve the workspace.
Search never replaces an open composer.

Result IDs are disclosed through the existing bounded helper list. Reading,
replying and attachments retain their selected-message fences. Explicit read/
unread, move and undo actions are disabled in this first search version at both
UI and helper boundaries; use the normal mailbox view for those operations.
The SDK may retain searched message metadata in its existing Mail database.
Queries travel only over private helper IPC and the pinned SDK's Proton transport,
never process arguments, environment, preferences, logs or a new search index.
Existing Mail at-rest storage limitations still apply; see [LOCAL_STORAGE.md](LOCAL_STORAGE.md).

The native adapter awaits the SDK's existing page-completion signal and requests
its full local callback snapshot, including empty results. It adds no search
transport or cryptography. Synthetic contracts cover old recipient-only matches,
query bounds, return navigation, retained drafts, expiry/lock, action refusal and
backward-compatible packets. Public SDK mock-server tests cover paging, keyword
changes and Spam/Trash scope. Real imported-message acceptance remains manual.
