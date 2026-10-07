# ProtonX

Native macOS clients for Proton Pass and Mail. Built with SwiftUI and AppKit,
Proton's existing Rust cores, separate product windows, and **one optional
menu-bar icon**. No bundled Electron or Chromium runtime.

**Developer alpha · macOS 14+ · Pass first.** ProtonX is independent of Proton AG
and licensed under GPL-3.0-or-later. Build from source to explore the native
interface or contribute. Signed, notarized binary releases are not yet available.

## Features

| Product | Available | Current limitations |
| --- | --- | --- |
| Pass | Account sign-in and local unlock; vault and Trash browsing; search and sorting; password copy/reveal; TOTP copy/setup/edit; login and note editing with multiple websites and custom fields; revision conflict protection; Trash/restore; encrypted saved-first loading and read-only offline browsing for eligible personal paid accounts | No native browser autofill, passkey operations, attachment handling, sharing UI or account switching. Other item types are readable but have no native editor. Managed accounts stay online-only. |
| Mail | Native username/password, TOTP and second-password sign-in; independent Keychain-backed session; folders and paged inbox; SDK conversation grouping with expandable message cards; formatted HTML reading on light paper; per-message image loading; read/unread, Archive/Trash/Inbox and move undo; compose, reply and reply-all; sending identity selection and draft saving | Live send/reply delivery and account recovery are acceptance gates. No human verification/FIDO-only login, file upload/viewing, rich-text editing or push UI. Search covers loaded subjects and senders, capped at 1,000 messages. |
| Drive | Planned | No Drive client implemented. |

Pass and Mail share window navigation and macOS integration, while keeping their
sessions and data separate. Keyboard commands follow the active product window.
Optional quick access, Touch ID/Mac-password unlock, screen-lock handling and
expiring password copies support everyday Mac workflows.

The official standalone Proton Pass Safari extension can continue to handle
website filling and supported browser passkeys. ProtonX does not share its local
session or lock state with that extension.

## Project status

Manual acceptance testing covers Pass login creation, bidirectional editing and
sync with the official desktop app, conflict refusal, Trash/restore and online
quit/restart. Native Mail sign-in and reading have also passed manual acceptance.
Automated tests cover synthetic protocol, security-policy and recovery cases;
they do not establish complete real-account interoperability.

This alpha is not a full replacement for the official apps. Start with synthetic
demo data or a disposable account. Important release gates include an independent
security review, broader account recovery testing, dependency licensing, signing
and notarization. **The default Mail SDK stores decoded messages in an unencrypted
local database.** An encrypted-storage candidate exists but is not enabled in
ordinary builds; migration and recovery remain release blockers. Read
[SECURITY.md](SECURITY.md) and the [storage review](docs/LOCAL_STORAGE.md).

## Build and run

Requires macOS 14+, Xcode 16+ / Swift 6, Python 3.11+, Git, and Rust 1.93+
(tested with Rust 1.99). Open Xcode and accept its license before building.
No Proton account or Apple signing account is needed to explore demo mode.
The build scripts do not install global dependencies.

```sh
git clone https://github.com/kevb/ProtonX.git
cd ProtonX
./scripts/build-app.sh
open build/ProtonX.app
```

Choose **Explore with demo data** for Pass or **Explore demo inbox** for Mail.
Use the visible **ProtonX** product switcher, **Products** menu, or ⌘1 / ⌘2 to
open either window. Demo data is synthetic and never accesses a Proton account.

Builds use ad-hoc signing by default. A configured identity provides stable
signatures, but prompt-free Keychain access across rebuilds is not established.
See [local signing](docs/LOCAL_SIGNING.md).

### Preview, updates and Spotlight launchers

```sh
./scripts/build-app.sh --preview       # Separate, synthetic-only preview app
./scripts/build-app.sh --stage-update  # Stage an update alongside a running app
./scripts/build-app.sh --install       # Install the suite and product launchers
```

Preview cannot sign in, restore a real session or register another menu-bar item
or global shortcut. Quit the installed app before updating or opening another
account-capable build. The installer verifies signatures, refuses running
binaries and retains previous builds.

**ProtonX Mail** and **ProtonX Pass** are native Spotlight launchers. Each opens
and focuses its product window in the shared ProtonX app, including minimized or
closed windows. See the [installation guide](docs/DAILY_USE_UPDATE.md).

## Sign in

### Pass

Choose **Sign In to Proton** to open Proton's account page in the macOS
authentication window. Proton's Rust SDK handles the desktop session handoff;
the vault interface remains native. Direct password sign-in is an experimental
alternative with unresolved server rejection; use the account-window flow.

After locking or restarting, **Unlock Pass** requires Touch ID or your Mac
password. **Sign Out** performs remote logout. ProtonX uses the pinned desktop
protocol and respects server permissions and product limits. The original CLI
product's eligibility policy remains separate.

Eligible personal paid accounts can restore an encrypted saved vault before
refreshing online. Saved access is read-only and lasts at most 24 hours, shortened
by known subscription/trial expiry. Changes, verification-code generation and
attachments require an online connection. See [offline scope](docs/OFFLINE_DESIGN.md).

### Mail

Open Mail and enter your Proton username/password, followed by an authenticator
code or second mailbox password if required. Normal onboarding requires no
Bridge installation, server ports, generated mail-client password or certificate
import. Human verification, security-key-only challenges and password-change
flows are currently unsupported; use the official client for those accounts.

**Unlock Mail** restores Mail's own session after local authentication. Locking
clears the interface and stops its helper; **Sign Out** ends the SDK account
session. Mail and Pass do not share authentication.

**Conversations** groups loaded folder messages using Proton's conversation IDs.
Opening a conversation fetches its message summaries, including sent replies,
with Proton's Trash visibility rules. Expand a card to read or reply to that
message; only one body is open at a time. The toolbar offers **Messages** for
individual browsing. Actions still affect one message. Conversations over 200
messages fall back to the selected message rather than showing a partial thread.
Search and list counts cover loaded folder messages, not the whole conversation.

The composer offers only sending identities provided by Proton's core, including
connected Gmail addresses where enabled. Queued, confirmed, failed and unknown
send outcomes remain distinct; an uncertain send is not automatically resubmitted
by the app. Live delivery and recovery tests remain required. See
[composer behavior](docs/MAIL_COMPOSER.md).

HTML messages retain headings, tables and styles on white paper in both system
appearances. Remote images start blocked; **Load images** enables them for the
selected message only. Message scripts remain disabled, links require an external
open confirmation, and plain text is always available. See
[reader boundaries](docs/MAIL_RENDERING.md).

**Connect using Bridge…** remains an advanced compatibility prototype. It uses
a separate eligible Bridge installation, generated client password and imported
public certificate, subject to Bridge's product limits.

## Keyboard and menu bar

- ⌘1 / ⌘2: open Pass / Mail.
- ⌘N / ⌘F / ⌘R: create, search and refresh in the front product window.
- In Mail: ⇧⌘U read/unread, ⌘E archive, ⌘Delete Trash, ⌘Return review before sending.
- ⌘L: lock both products. ⌘,: settings. ⌘Q: quit.
- Optional ⌃⌥P: bring Pass forward and focus search.
- Settings can hide the menu-bar icon. The Dock and Window menu remain available.
  Closing windows keeps the suite running; Quit ends it.

## Contribute

Contributions are welcome. Current priorities are secure Mail storage and
migration, account recovery, broader Pass item interoperability, accessibility
and measured startup/resource use. The [roadmap](docs/ROADMAP.md) describes scope
and acceptance criteria; [CONTRIBUTING.md](CONTRIBUTING.md) covers development and
review. Use synthetic content in tests, screenshots and public bug reports.

```sh
swift test
./scripts/test-bridge.sh             # Synthetic IMAP/SMTP with verified TLS
./scripts/test-bridge.sh --starttls   # Same round trip with STARTTLS
./scripts/test-helper.sh             # Public Pass SDK/CLI and native contracts
./scripts/test-mail-helper.sh        # Native Mail IPC and public/synthetic tests
./scripts/test-credential-provider.sh # Compile-only native AutoFill probe
```

Detailed coverage and remaining acceptance gates live in
[validation](docs/VALIDATION.md) and [Pass reliability](docs/PASS_RELIABILITY.md).
See [architecture](docs/ARCHITECTURE.md) for the suite/separate-app tradeoffs and
[performance](docs/PERFORMANCE.md) for the measurement plan. Resource savings
against official clients require matched benchmarks; no reduction percentages
are established.

For isolated live testing, the [test-account workflow](CONTRIBUTING.md#live-account-validation)
provides an optional native credential form and synthetic-record checks. Never
put credentials, session handoff URLs or private mailbox/vault content in issues
or logs. Binary publication awaits the [dependency license review](docs/LICENSE_REVIEW.md).
