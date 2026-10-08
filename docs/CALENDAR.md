# Native Calendar

Open Calendar from Home, the product rail, **Products → Open Calendar** (⌘3),
or `protonx://calendar`. The normal app offers a native sign-in form and an
explicit synthetic preview. The isolated preview bundle uses sample data only.

## Connected browsing (experimental)

Sign in with a Proton username and password. TOTP and two-password accounts
have native challenge fields. CAPTCHA and security-key-only authentication are
not supported yet; these flows stop with a verification message. Calendar owns
its session independently of Mail and Pass.

The read-only adapter lists calendars and decrypts events for the displayed date
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

**Connected event creation, editing and deletion are disabled.** The helper has
no event mutation command, and its Calendar API wrapper rejects writes. Sign-in,
Proton session refresh/scope verification and sign-out still use authentication
endpoints. There are no invitations, reminders, notifications or EventKit exports.

This is an experimental connection milestone. Synthetic SRP/key/decryption and
recurrence tests pass; no real Calendar account has been connected during this
milestone's validation. The reused adapter does not verify detached signatures
on Calendar passphrases/cards. Signature verification, independent security review
and disposable-account interoperability remain release gates. See [SECURITY.md](../SECURITY.md).

## Session and storage

The macOS helper stores session tokens and the derived key-unlock passphrase in
`org.kevb.ProtonX.Calendar.Native`, a dedicated, nonsynchronizing Keychain entry.
The login password is not persisted. Saved-session restore follows native local
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
sign-in, TOTP, mailbox-password, restore, date-range snapshot and sign-out.
Credentials never enter process arguments/environment or diagnostic output.
`Resources/CalendarProtocol.json` records the fixed API origin and limits:
62 days per range, 64 calendars, 5,000 occurrences and 8 MiB per reply.

Run `scripts/build-calendar-helper.sh`, `scripts/test-calendar-helper.sh` and
`swift test --build-system native`. Tests use in-memory storage, Proton's local
SRP test server and synthetic OpenPGP/calendar data; they do not touch Keychain
or real accounts.
