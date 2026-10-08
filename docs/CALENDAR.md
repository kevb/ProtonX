# Native Calendar preview

Calendar is an early native interface, available from Home, the product rail,
**Products → Open Calendar** (⌘3), or `protonx://calendar`. The normal application
opens an explicit preview welcome screen. Choose **Explore Calendar preview** to
load synthetic events. The isolated preview bundle opens sample data directly.

## Available

- Monday-first week timetable, month grid and a fourteen-day agenda.
- Today, previous/next navigation, mini-month date selection and time zones.
- Independent visibility and colours for sample Personal and Work calendars.
- Search by event title or location within the sample calendar.
- Timed and all-day events, multi-day spans and overlapping timetable lanes.
- An event inspector and inline editor for title, calendar, start/end, location
  and notes. Delete requires confirmation. Refresh retains acknowledged edits.
- Product switching retains the selected date, view, filters and unfinished
  Calendar editor alongside an unfinished Mail composer.

All changes remain in memory. Lock, window close and Quit discard them, including
unfinished editors. There is no Proton Calendar authentication or sync, persistent
calendar storage, Apple Calendar export, invitations, recurrence or reminders.
No preview operation sends email or contacts Proton servers.

## Dates and time zones

Timed events retain absolute start/end instants and their event time zone.
Changing the viewing zone changes the displayed clock times, without changing
those instants. The editor uses the event's zone. Changing its zone preserves the
instants; editing the clock fields then changes the instants in that zone.

All-day events retain civil dates independent of offsets. Their end is exclusive
in the model; the editor shows the last included day. Day/week arithmetic uses
calendar dates rather than fixed 24-hour increments across daylight-saving
transitions. Events ending at midnight do not occupy the following day.

The timetable currently uses a 24-hour wall-clock grid. During the repeated hour
at a daylight-saving transition, agenda/inspector times and absolute durations
remain authoritative; the grid does not render a second hour lane. This needs a
transition-day layout before full Calendar parity.

## Proton integration boundary

`CalendarDataSource` accepts bounded typed event snapshots and per-event writes,
with revision checks. The only implementation is `PreviewCalendarDataSource`.
`CalendarStore` validates snapshots, rejects stale delete intents and late
responses after lock, and keeps the editor open after a failed save. A future
backend must supply its own account, key management, storage and session lifecycle.
Mail and Pass credentials are not shared with Calendar.

The pinned `ProtonMail/clients` revision in `upstream.lock.json` includes Calendar
invitation handling under the Mail project, but no standalone Calendar project.
The pinned WebClients source supplies the fuller Calendar reference. The official
[iOS Calendar repository](https://github.com/ProtonMail/ios-calendar) also records
build dependencies that are not publicly available. These findings guide adapter
research; they do not rule out a native implementation.

Before enabling account operations, pin and license-review the chosen upstream
implementation, reuse Proton cryptography, and establish independent session and
encrypted local-storage contracts. First exercise read-only calendar/event
browsing, key recovery, bounded date ranges, recurrence expansion and exceptions;
then validate per-event mutations and cross-client interoperability using a
disposable account. Mail invitation/RSVP integration remains a separate feature.

## Validation

Synthetic tests cover civil dates, daylight-saving boundaries, half-open spans,
intersection layout, time zones, invalid data, per-event revision conflicts,
preview editing, filtering, cross-product editor retention and lock epochs.
These checks establish preview behavior, not Proton account interoperability.
