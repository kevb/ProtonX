# ProtonX

Native macOS clients for people who want the Proton suite to feel at home on Mac.
SwiftUI and AppKit, Proton's existing cryptography, independently usable product
windows, and **one optional menu-bar icon**. Native vault and mail UI, without a bundled Electron or Chromium runtime.

**Status: 0.1 developer alpha.** Pass is the priority. This is a working native
client built on Proton's open-source Rust Pass and Mail cores with separate
desktop product protocols and sessions. It is not a full replacement for all official apps.
Initial user-driven sign-in, local unlock and vault loading have been observed.
The user reported a successful create/sync/delete test login. Editing and session
recovery still need validation; direct Mail account interoperability is unverified. Use a disposable test
account before trusting this alpha with your vault.
Builds are available locally; binary publication also awaits the recorded
[dependency license review](docs/LICENSE_REVIEW.md).

ProtonX is independent of Proton AG. GPL-3.0-or-later.

## What works

| Product | Implemented | Current limits |
| --- | --- | --- |
| Pass | macOS authentication window and experimental native password prompts; atomic vault/Trash loading, title search and sorting; on-demand item details; password copy and reveal; TOTP copy/setup/edit; create/edit logins and notes with multiple websites and text/hidden custom fields; revision conflict protection; trash/restore; remote sign-out | no browser autofill, passkey operations, attachments, sharing UI, account switching, or offline UI |
| Mail | Direct native username/password, TOTP and second-password flow; separate Keychain-backed session restoration; folders, paged message list and selected-message decryption through Proton’s Mail SDK; safe text reader | Read-only direct client; account interoperability unverified; no human verification/FIDO-only login, threading, attachments, sending or push UI. Search covers loaded metadata, capped at 1,000 messages. Bridge compose remains an advanced prototype |
| Drive | Architecture decision and planned integration boundary | No Drive client implemented |

Native behavior: standard windows and toolbars, keyboard commands, light/dark
appearance, VoiceOver labels, optional global quick access, local-device unlock,
sleep/screen-lock handling, inactivity lock, and a clipboard that clears its own
secrets after 30 seconds. Demo mode is explicitly synthetic and never connects
to Proton or writes account credentials.

## Build and run

Requires **macOS 14+**, **Xcode 16+ / Swift 6**, Python 3.11+, Git, and a stable Rust
toolchain 1.93+ (tested with Rust 1.99). Quit ProtonX before rebuilding its bundle.
First launch Xcode and accept its license. No
signing account or Proton credentials are needed to build or explore demo mode.

```sh
git clone https://github.com/kevb/ProtonX.git
cd ProtonX
./scripts/build-app.sh
open build/ProtonX.app
```

Choose **Explore with demo data** to inspect Pass. Use **Products → Open Mail**
to sign in or explore the separate demo inbox. Build output defaults to ad-hoc
signing; a configured identity gives stable signatures. See
[local signing and its measured Keychain limits](docs/LOCAL_SIGNING.md). It is not notarized. No global dependencies are installed by the build scripts.

For UX testing alongside a running session, `./scripts/build-app.sh --preview`
builds `build/ProtonX Preview.app`: synthetic Pass/Mail data only, a separate bundle
identity, no sign-in and no extra menu-bar item or global shortcut registration.
`./scripts/build-app.sh --stage-update` builds `build/ProtonX Update.app` without
replacing a running primary bundle. Quit the old app before opening the update;
both real bundles use the same isolated ProtonX Pass profile.

Both helpers are built from exact Proton source revisions. Pass runs for one
operation and exits; Mail persists while its window is unlocked and stops on lock/close. It uses a separate encrypted
profile and Keychain namespace; it does not import the official app's session.
To download every reviewed upstream repository:

```sh
python3 scripts/bootstrap.py --references
```

## Connect Pass

Click **Sign In to Proton**. A macOS authentication window opens Proton's account
page for a desktop session handoff. The existing Rust SDK creates, polls and
decrypts that one-use handoff; the secret URL stays in private IPC and memory.
The window closes when sign-in/setup completes. Cancel or locking cancels both
it and the helper. The vault interface stays native after sign-in.

**Try direct password sign-in (experimental)** provides native password/TOTP,
second-password and extra-password prompts. A live attempt was rejected with
HTTP 422 / API 8004; its exact cause is not established. The earlier CLI backend
successfully authenticated but failed CLI eligibility. Neither outcome establishes
complete desktop vault interoperability. The corrected desktop account handoff
has reached a live vault after user authentication and local unlock; security-key,
SSO, verification and recovery behavior still need validation.

Encrypted session/cache files belong to the helper; their local encryption key
is in macOS Keychain. ProtonX uses the pinned macOS desktop protocol and does not
apply the CLI-specific eligibility check. Product permissions and account limits
still apply. The API compatibility identifier comes from reviewed desktop source;
the User-Agent identifies ProtonX. See [the backend decision](docs/ARCHITECTURE.md).
Server failures expose only a fixed category and numeric HTTP/API codes.

After restarting or locking, **Unlock Pass** uses Touch ID or your Mac password.
Lock is a local UI boundary, not a server-session revocation; **Sign Out** performs
remote logout and removes this app's local session after it succeeds.

## Connect Mail

Choose **Products → Open Mail** (⌘2) and enter your Proton username/password.
If required, enter an authenticator code or your second mailbox password in the
native form. There are no ports, generated passwords or certificates in the
normal onboarding. The direct Mail core is now packaged; live server acceptance
and end-to-end account recovery still need designated-account validation.
See [the native Mail integration and acceptance gates](docs/MAIL_NATIVE_SIGN_IN.md).

Mail keeps its own encrypted session and Keychain entries. On restart, **Unlock
Mail** uses Touch ID or your Mac password before restoring that session. Locking
clears the UI and stops Mail’s helper. Sign Out ends its SDK account session.
Pass and Mail do not share authentication. Accounts requiring human verification,
a security-key-only challenge or a password change currently receive an explicit
unsupported state; use Proton’s official client for those flows.

This first direct client reads mail. It does not send, reply, mark read/unread,
archive, manage attachments or display conversations yet. Refresh updates the
loaded view; search filters loaded subjects and senders. No remote images/scripts
are executed. **Explore demo inbox** uses synthetic data with no account access.

**Connect using Bridge…** is an optional compatibility prototype under sign-in.
It retains the existing local TLS reader and confirmed plain-text compose/send.
A separate eligible Bridge installation, generated client password and imported
public certificate are required there. It is independent of direct Mail login
and remains subject to Bridge’s product limits. No automatic send retry is added.

## Keyboard and menu bar

- ⌘1 / ⌘2: open Pass / Mail.
- ⌘N: new Pass item. ⌘F: search Pass. ⌘R: refresh Pass.
- ⌘L: lock both products. ⌘,: settings. ⌘Q: quit.
- Optional ⌃⌥P: bring Pass forward; focus search.
- Settings can remove the ProtonX menu-bar item entirely. The Dock and Window menu
  remain available. Closing windows keeps the suite running; Quit ends it.

## Test

```sh
swift test
./scripts/test-bridge.sh        # Synthetic IMAP/SMTP servers, verified TLS
./scripts/test-bridge.sh --starttls # Same round trip with STARTTLS
./scripts/test-helper.sh        # Public SDK/CLI tests plus native transport contracts
./scripts/test-mail-helper.sh   # Native Mail IPC, public synthetic decryption and paging
./scripts/test-credential-provider.sh # Compile-only API probe and synthetic origin cases
```

See [validation](docs/VALIDATION.md) for exact results and untested boundaries,
[architecture](docs/ARCHITECTURE.md) for the separate-app/suite tradeoffs,
[security](SECURITY.md), [UX review](docs/UX_REVIEW.md), and
[contributing](CONTRIBUTING.md). Resource claims require measurement:
[scripts/measure-resources.sh](scripts/measure-resources.sh) and
[performance notes](docs/PERFORMANCE.md).

## Optional designated test account

Normal builds/tests need no account. For a disposable account, sign in through
ProtonX, then run `./scripts/test-account.sh prepare` and
`./scripts/test-account.sh session`. This performs live synthetic note
create/read/edit/trash/restore checks in the same local Pass profile and leaves
one clearly named synthetic note in recoverable Trash. Do not use a primary vault.
Quit ProtonX before rebuilding; close or lock it before running the helper tests
against its profile.

For unattended **experimental direct password** validation, run `prepare`, then
`setup`, and enter the password in the native secure field. `check` reports only
readiness; `run` consumes the saved test credential and removes it after the
attempt, including failure; `clear` removes it without testing. The tool is
separate from the app bundle. See [security](SECURITY.md).
