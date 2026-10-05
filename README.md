# ProtonX

Native macOS clients for people who want the Proton suite to feel at home on Mac.
SwiftUI and AppKit, Proton's existing cryptography, independently usable product
windows, and **one optional menu-bar icon**. No Electron, Chromium, or web UI.

**Status: 0.1 developer alpha.** Pass is the priority. This is a working native
client built on Proton's open-source Pass client, plus an initial native Mail
client for Proton Bridge. It is not a full replacement for all official apps.
Real-account interoperability has not yet been validated. Use a disposable test
account before trusting this alpha with your vault.

ProtonX is independent of Proton AG. GPL-3.0-or-later.

## What works

| Product | Implemented | Current limits |
| --- | --- | --- |
| Pass | Native username/password and verification prompts; vault browsing and search; on-demand item details; password copy and reveal; TOTP copy; create logins/notes; edit login/note fields; trash/restore; remote sign-out | Proton CLI eligibility applies; no browser autofill, passkey operations, attachments, sharing UI, account switching, or offline UI |
| Mail | Native mailbox/message lists; plain-text MIME reader; single-recipient plain-text compose/send; Bridge credentials in Keychain; verified local TLS | Requires a running, eligible Proton Bridge account; newest 25 messages per mailbox; no attachment handling, HTML rendering, reply threading, push or direct Proton login |
| Drive | Architecture decision and planned integration boundary | No Drive client implemented |

Native behavior: standard windows and toolbars, keyboard commands, light/dark
appearance, VoiceOver labels, optional global quick access, local-device unlock,
sleep/screen-lock handling, inactivity lock, and a clipboard that clears its own
secrets after 30 seconds. Demo mode is explicitly synthetic and never connects
to Proton or writes account credentials.

## Build and run

Requires **macOS 14+**, **Xcode 16+ / Swift 6**, Python 3, Git, and a stable Rust
toolchain (tested with Rust 1.99). First launch Xcode and accept its license. No
signing account or Proton credentials are needed to build or explore demo mode.

```sh
git clone https://github.com/kevb/ProtonX.git
cd ProtonX
./scripts/build-app.sh
open build/ProtonX.app
```

Choose **Explore with demo data** to inspect Pass. Use **ProtonX → Open Mail**
to explore the separate demo inbox. Build output is ad-hoc signed for local use;
it is not notarized. No global dependencies are installed by the build scripts.

The helper is built from an exact Proton source revision. It runs only when a
Pass operation is requested, and exits afterwards. It uses a separate encrypted
profile and Keychain namespace; it does not import the official app's session.
To download every reviewed upstream repository:

```sh
python3 scripts/bootstrap.py --references
```

## Connect Pass

Click **Sign In to Proton**. ProtonX asks for credentials through native fields;
Proton's Rust client performs authentication and handles supported second-password,
TOTP and extra-password challenges. Your account password is not saved by the UI.
Encrypted session/cache files are owned by the helper; their local encryption
key is in macOS Keychain. Standard password/TOTP authentication is the implemented
path. SSO, security-key login and human-verification challenges are not implemented.
Proton's server-side CLI access restrictions are retained, so account eligibility
may prevent login even where the official Pass desktop app works.

After restarting or locking, **Unlock Pass** uses Touch ID or your Mac password.
Lock is a local UI boundary, not a server-session revocation; **Sign Out** performs
remote logout and removes this app's local session after it succeeds.

## Connect Mail

Start [Proton Bridge](https://proton.me/mail/bridge), sign in there, and open its
mail-client configuration. Enter that email address, Bridge-generated password,
IMAP/SMTP ports and TLS mode into ProtonX Mail. Export Bridge's **public** TLS
certificate and import the PEM file. Do not import a private key. ProtonX only
connects to `127.0.0.1`, requires TLS, validates the certificate and hostname, and
never disables verification. Bridge remains responsible for Proton authentication,
message encryption and remote sync. Bridge may retain its own menu-bar item;
ProtonX doesn't change its settings or manage its lifecycle in this release.

Sending requires an explicit final confirmation in the app. If a send times out,
check Sent before retrying: a lost acknowledgement can mean mail was delivered.

## Keyboard and menu bar

- ⌘1 / ⌘2: open Pass / Mail.
- ⌘N: new Pass item. ⌘F: search Pass. ⌘R: refresh Pass.
- ⌘L: lock both products. ⌘,: settings. ⌘Q: quit.
- Optional ⌃⌥P: bring Pass forward; focus search on macOS 15+.
- Settings can remove the ProtonX menu-bar item entirely. The Dock and Window menu
  remain available. Closing windows keeps the suite running; Quit ends it.

## Test

```sh
swift test
./scripts/test-bridge.sh        # Synthetic IMAP/SMTP servers, verified TLS
./scripts/test-bridge.sh --starttls # Same round trip with STARTTLS
./scripts/test-helper.sh        # Public upstream tests plus native-pipe smoke test
```

See [validation](docs/VALIDATION.md) for exact results and untested boundaries,
[architecture](docs/ARCHITECTURE.md) for the separate-app/suite tradeoffs,
[security](SECURITY.md), [UX review](docs/UX_REVIEW.md), and
[contributing](CONTRIBUTING.md). Resource claims require measurement:
[scripts/measure-resources.sh](scripts/measure-resources.sh) and
[performance notes](docs/PERFORMANCE.md).
