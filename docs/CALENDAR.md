# Native Calendar

Open Calendar from Home, the product rail, **Products → Open Calendar** (⌘3),
or `protonx://calendar`. The normal app reuses an unlocked ProtonX account and
offers an explicit synthetic preview. The isolated preview bundle uses sample data only.

## Connected browsing (experimental)

Calendar connects from an unlocked Mail or online Pass account using Proton's
one-use session fork. There is no second username/password form in the normal
suite flow. If the existing account is locked, **Unlock Mail/Pass to continue**
opens its local Touch ID screen and returns to Calendar after unlock. Switching
elsewhere cancels that return. With two unlocked accounts, choose the source;
Calendar never silently replaces its already-saved account.

**Use another account** retains native password/TOTP/two-password sign-in.
CAPTCHA and security-key-only authentication are not supported yet. Proton may
refuse to fork an existing child/limited session; the UI shows a retry/fallback
rather than duplicating tokens or bypassing server rules. Calendar still owns
separate child tokens, keys, local unlock and sign-out. Parent-account revocation
can affect a linked child session according to Proton's server policy.

The adapter lists calendars and decrypts events for the displayed date
range. Changing the date, view or time zone fetches that range; Refresh fetches
it again. Week, month and fourteen-day agenda views share visibility filters,
title/location search and an event inspector. Search covers the loaded range,
not the entire account. Product switching retains the view and a Mail draft.

Recurring events use the pinned adapter's expansion, including EXDATEs and
modified occurrences. Malformed or excessive recurrence results fail the range
rather than silently falling back to a master or truncating results. Undecryptable
occurrences are omitted with an explicit warning. A failed refresh retains the
previous visible snapshot and shows an error. Shared, subscribed and older-key
calendars still need account interoperability testing.

## Connected event creation and editing (experimental)

**New event** opens a native editor for an owned personal calendar. Select a
calendar, enter a title, timed or all-day dates, time zone, location and notes,
then **Save event** (⌘S). Selecting a supported event exposes **Edit event**.
The editor stays open when switching products. New events inherit calendar
reminders; edits preserve existing reminder settings, colour and untouched
signed/encrypted iCalendar properties. All-day ends in the editor are inclusive;
the helper sends exclusive UTC civil dates. Proton's 1970–2037 date bounds and
text limits apply to connected saves.

Each save submits exactly **one encrypted event**, in one calendar, using pinned
Proton OpenPGP. Fresh ownership and member identity checks, verified calendar
passphrase/key material and verified event-card signatures gate writes. Only the
active primary calendar key is used. There is no batch import, overwrite, event
deletion or arbitrary endpoint through this command. Calendar moves, recurring
series/exception edits, shared/subscribed calendar writes, guests, invitations,
conferencing, reminder editing and native event notifications remain unavailable.
The inspector explains unsupported edits instead of offering an unsafe action.

Before editing, the helper fetches the exact event and compares a digest of the
complete API row, including metadata the adapter does not otherwise interpret.
A mismatch preserves the draft and refuses the save. **This is an optimistic
preflight, not an atomic server revision condition:** the currently referenced
sync API has no conditional revision field, so a concurrent change in the
interval between the check and save can still race. Cross-client acceptance and
an independent protocol review remain necessary before production release.

Writes are never automatically retried, including HTTP 401/429. If a reply is
lost or cannot be validated, further saves are blocked until a successful
**Refresh**. The draft is retained. Check whether the event saved before
continuing. A retained new-event draft has a stable UID; retry after refresh
reconciles that UID instead of creating another copy. For a conflicting edit,
cancel the retained draft and reopen the refreshed event. Lock/quit clears drafts;
uncertain-write recovery is not durable across those boundaries.

Synthetic SRP/key/decryption, creation/update, conflict, uncertainty and recurrence
contracts pass. The reader retains its existing experimental, lenient detached
signature handling; the stricter checks described above apply to **writes**.
Independent security review, broader read-signature verification, older-key
handling and real-account create/edit interoperability remain release gates.
See [SECURITY.md](../SECURITY.md).

## Session and storage

The macOS helper stores session tokens and the derived key-unlock passphrase in
`org.kevb.ProtonX.Calendar.Native`, a dedicated, nonsynchronizing Keychain entry.
The login password is not persisted. Account handoff carries a one-use selector,
canonical user ID and derived key-unlock secret over private pipes only, with a
120-second local lifetime. The child account and unlocked key identity must both
match the source. Keys/tokens are staged in memory until the app rechecks the
unlocked source and explicitly commits; existing Calendar credentials are never
replaced by this path. There is no automatic replay after ambiguous failure.
An interrupted handoff may leave an unused child session on Proton's server;
clearing local state does not guarantee remote revocation. Saved-session restore follows native local
Touch ID/Mac-password authentication. The configured stable signing identity also
signs the Calendar helper; ad-hoc builds can need new Keychain authorization after
rebuilds. No Keychain access rule is weakened.

Events, unlocked keys and filters remain in memory. Lock, window close and Quit
clear Calendar state and terminate its helper. There is no persistent event cache
or offline browsing. The profile directory contains only a process lock file;
the community adapter's plaintext session/config/cache paths are disabled.

## Preview editing

**Explore Calendar preview** loads fictional Personal and Work calendars. The
preview supports timed/all-day event creation, editing and confirmed deletion,
with revision checks. All changes and unfinished editors reset on lock/quit.
Preview operations never connect to Proton or access account credentials.

## Dates and time zones

Timed events retain absolute start/end instants and the event's time zone.
Changing the viewing zone changes displayed clock times. All-day events retain
civil dates independent of offsets, with an exclusive end. Day/week arithmetic
uses calendar dates across daylight-saving transitions. Events ending at midnight
do not occupy the following day.

The timetable currently uses a 24-hour wall-clock grid. During the repeated hour
at a daylight-saving transition, agenda/inspector times and absolute durations
remain authoritative; a separate repeated-hour lane remains on the roadmap.

## Source and protocol

`upstream.lock.json` pins the unofficial, Unlicense
[proton-cal adapter](https://github.com/cheeseandcereal/proton-cal) at
`5ff2791a0823ffbd592c3c95808819d40d4e639a`. Official Proton `go-proton-api`,
`go-srp` and `gopenpgp` dependencies perform SRP, key unlocking and OpenPGP.
`Resources/CalendarHelper.mod` and `.sum` pin dependencies; the native materializer
preserves original source notices while replacing storage, removing CAPTCHA
console/browser workarounds and imposing transport/recurrence limits.

The helper uses private, bounded JSON lines on stdin/stdout. It accepts only
sign-in, TOTP, mailbox-password, one-use account handoff/commit, restore,
date-range snapshot, a bounded single-event save and sign-out.
Credentials never enter process arguments/environment or diagnostic output.
`Resources/CalendarProtocol.json` pins the Calendar client identity from the
public web bundle (URL and SHA-256), fixed API origin and limits:
62 days per range, 64 calendars, 5,000 occurrences and 8 MiB per reply.

Run `scripts/build-calendar-helper.sh`, `scripts/test-calendar-helper.sh` and
`swift test --build-system native`. Tests use in-memory storage, Proton's local
SRP test server and synthetic OpenPGP/calendar data; they do not touch Keychain
or real accounts.
