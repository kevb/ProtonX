# Native notifications

Open **ProtonX → Settings → Notifications**. Choose **Enable notifications** and
allow the native macOS request. Banners, alert style, Focus, lock-screen previews
and per-app sound permissions remain under **macOS System Settings → Notifications**.
The pane links there and offers a synthetic **Send test notification**.

## Mail

- New-email alerts are opt-in. Sound and unread Dock counts have separate controls.
- Private previews are the default; sender and subject require explicit opt-in.
- Alerts originate from committed server CREATE events through Proton's pinned
  SDK, not snapshots. Reading, importing, marking unread, moving, refreshing and
  loading older pages do not themselves create alerts.
- The outline follows the official Mail client: unread, non-imported arrivals,
  Inbox/category notification preferences, starred mail and enabled custom
  folders. Spam/Trash are excluded. Connected Gmail mail uses the same Proton
  labels/events as other received mail; no Gmail credentials or direct Gmail
  notification transport are introduced.
- More than three arrivals in one batch are grouped into a private count alert.
  Queue, dedupe and click-ticket storage are bounded and memory-only.
- Clicking an alert brings Mail forward and opens its message when present in
  the current bounded mailbox page. An open draft is preserved. A stale alert
  never bypasses local authentication or opens a message from another session.
- ProtonX must be running and Mail unlocked. Switching to Pass keeps the Mail
  monitor alive. Lock, close, sign-out or expiry clears alerts and the badge.
  There is no background login, APNS device registration or locked-state push.
- The SDK's existing event polling interval is 60 seconds. The adapter reads the
  local event queue every five seconds. Notifications therefore are not instant
  push; network interruptions can delay them. Snoozed-reminder alerts remain on
  the roadmap.

## Pass

The official desktop Pass code uses in-app notices rather than an alert for each
vault create/edit/sync. ProtonX keeps these operations quiet. Sharing and Pass
Monitor notices belong to those future feature implementations, with separate
product sessions.

## Source references and validation

The official outline is pinned by `upstream.lock.json`:

- [Mail arrival filters](https://github.com/ProtonMail/WebClients/blob/0b1d912065235b251adc545c1d91cb615bfab73b/applications/mail/src/app/hooks/mailbox/notifications/useNewEmailNotification.ts)
- [Mail alert content and navigation](https://github.com/ProtonMail/WebClients/blob/0b1d912065235b251adc545c1d91cb615bfab73b/applications/mail/src/app/hooks/mailbox/notifications/notificationHelpers.ts)
- [Desktop OS notifications and badges](https://github.com/ProtonMail/WebClients/blob/0b1d912065235b251adc545c1d91cb615bfab73b/applications/inbox-desktop/src/ipc/notification.ts)
- [Proton's desktop notification guide](https://proton.me/support/desktop-notifications)
- [Apple's permission API](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications)

Swift contracts use an injected OS sink for permission, privacy, batching,
deduplication, click scope, revocation and late-completion/lock races. Mail SDK
fixtures use public synthetic data and local mocks for V5/V6 committed events,
imports/updates/read mail, custom-folder preferences and category rules. No test
connects to a real Proton account. Native permission/banner acceptance can be
checked with the settings pane's synthetic test alert; real incoming-mail
acceptance remains separate from these contracts.
