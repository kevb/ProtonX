# Architecture decisions

## Separate windows, shared integration

We considered four models:

| Model | Strength | Cost |
| --- | --- | --- |
| Entirely separate apps | Independent updates, quitting and permissions; familiar product identities | More Dock/menu-bar entries; duplicated settings, login/session scaffolding and helpers |
| One combined workspace | One process and installation; obvious product switching | Mail competes with vault tasks; password unlock can unnecessarily disrupt mail; larger failure/security boundary |
| Separate apps plus coordinator | Independent sandboxes with one menu-bar entry | IPC, coordinator lifecycle and version negotiation; the coordinator can become a hidden mandatory service |
| One suite, separate product windows | Shared OS integration with familiar task boundaries; no coordinator process | Shared process/address space and update cadence; closing a product isn't quitting an app |

**0.1 chooses one suite workspace with a product rail.** Pass and Mail have
independent sessions, state, unlock prompts and adapters. A shared menu-bar icon
is optional. Product views don't call each other's APIs. The navigation does not
turn the vault into a tab inside an email app. A future separately distributed
Pass or Mail binary can share ProtonXCore, but separate product processes and
sandboxing require another decision and tests, not merely changing a target name.

Product launchers send a product-only URL without activating the suite themselves.
One application delegate handles that URL; a shared window router waits for launch
completion and the requested SwiftUI scene's native window, then restores and
raises that specific window. Product menus and shortcuts use the same router.
Existing windows are reused, closed windows are recreated, and a later request
supersedes any pending earlier focus action. This shares navigation only, not
product accounts or sessions.

## Modules

- `ProtonXApp`: SwiftUI views, AppKit menu bar/hotkey integration, system lock
  notifications, local authentication, visible-state management and clipboard.
- `ProtonXCore`: product models, safe URL/input policies, generation invalidation,
  Keychain access, adapters and bounded private process transport.
- `CBridgeTransport`: small system-libcurl boundary. Handles IMAP/SMTP transport,
  TLS verification, cancellation and output bounds. It does not implement Proton crypto.
- Pinned Proton Pass helper: a native desktop build of Proton's Rust Pass library
  and command implementation. Retains Proton's encryption, SRP/authentication,
  product APIs and sync.
  All secret-bearing create/update data uses stdin. Native authentication is a
  private line-oriented challenge protocol, independent of terminal control.

No permanent Pass helper, embedded web product UI, Electron or JavaScript
runtime is loaded in ProtonX. The system browser is used only during authentication. Helpers start on demand. Commands serialize to avoid racing encrypted
session refreshes and SQLCipher writes. Pass list responses contain metadata;
secret details are fetched for the selected item. Generation tokens prevent late
responses from restoring a locked window or a previous selection.

## Upstream reuse

The desktop WebClients and native iOS sources were downloaded and reviewed.
The published Pass macOS target contains a placeholder. The iOS Client package
also refers to an absent `LocalPackages/PassRustCore` package and mixes iOS UI
packages into its client dependency graph. Porting that entire project would
carry substantial unfinished platform work. The public Rust Pass client is the
usable shared implementation today. This is actual runtime reuse, not a newly
written Proton cryptographic stack or an embedded website.

`upstream.lock.json` records the original repositories and revisions.
`Resources/PassHelper.lock` pins the build's resolved transitive dependencies.
`patches/pass-cli.patch` is the full behavioral delta from upstream, applied by
a checked script.

## Desktop protocol, not CLI eligibility

The first adapter used the unmodified CLI product policy, which requires both
`PassCanUseCli` and the account's `CliAllowed` entitlement. A live account reached
successful authentication but failed that product-specific check. That is not a
requirement of a native password-manager UI.

ProtonX now builds an explicit `protonx-desktop` feature. Only that build **and**
the private native transport select the desktop policy. The original CLI identity
always retains its CLI eligibility check. We do not build the upstream
`no-login-restriction` feature.

The native helper uses `x-pm-appversion: macos-pass@1.42.0`, the protocol identity
from the pinned Electron desktop source. This is a compatibility identifier,
not a claim that ProtonX is an official Proton app. Its User-Agent identifies
`ProtonX/0.1.0`. `Resources/DesktopProtocol.json` and the build-time contract check
bind the identity/version to the immutable WebClients revision. TLS, SRP,
encryption, server responses and product limits remain in Proton's library.

The primary sign-in uses Proton's existing device-fork account flow targeting
`macos-pass`, displayed in `ASWebAuthenticationSession` with an ephemeral browser
session. The same pinned account source accepts the desktop child identity for
`/desktop/login`; it checks the child matches the selected Pass product. The Rust
SDK owns fork creation, polling, authenticated payload decryption and setup. Only
the child identity is parameterized; the original CLI keeps `cli-pass`. No fork
URL/token is printed, stored in preferences or passed as an argument. A strict
native URL allowlist accepts only the pinned production account destination.
Cancellation and successful helper completion close the authentication window.

An experimental direct SRP/password/TOTP path remains available. The desktop
protocol's live attempt failed with HTTP 422 / API 8004, also observed with an
obviously synthetic identity; the exact server-side cause is unresolved. We do
not classify this as a wrong password or CLI entitlement issue. The corrected account-fork
implementation supports desktop account sign-in and local unlock. Manual
fictional-login acceptance covers cross-client edits/sync, conflict refusal,
Trash/restore and online restart. Broader challenge and expiry/revocation coverage
remain acceptance gates.
Neither branch has established full security-key/SSO/challenge parity.

The desktop helper restricts its command surface to the native UI contracts.
CLI automation, agents, PATs, process injection, bulk secret export and permanent
deletion are rejected before opening a client in desktop mode. The original CLI
mode retains its original commands and eligibility policy.

## Native snapshot and editor contracts

`native-snapshot` bootstraps once and returns an atomic metadata-only active/Trash
snapshot, share permissions and plan capabilities. It replaces `2 + vaultCount`
helper starts with one for a refresh; Proton API calls still run per required
resource. A selected item is fetched separately. No background polling is added.

`native-create` and `native-edit` accept bounded typed JSON through stdin. Existing
Proton encryption and single-item requests handle writes. Native creation uses
its existing create permission guard; native editing uses its update guard and a
revision check before the existing encrypted update path. The CLI build keeps its
own original command surface and policy. Unchanged TOTP setup, modern URL modes,
passkeys and unsupported custom fields are preserved. Explicit custom-field
changes reference original indices/names/types and are revision-bound.

The UI closes an editor only after acknowledged success. It distinguishes a
subsequent failed refresh, retains failed drafts, and requires refresh before
further writes. Last-loaded in-memory data is not durable offline support.
See [offline design](OFFLINE_DESIGN.md) and the isolated
[credential-provider feasibility probe](CREDENTIAL_PROVIDER.md).

## Mail and Drive

The default Mail window uses Proton's native Rust Mail SDK through one bounded,
serial private helper. It runs while Mail is unlocked, with its own separate
profile and `org.kevb.ProtonX.Mail.Native` Keychain service. Native forms drive
credentials/TOTP/second-password states. Saved-session restore follows local
Mac authentication. The SDK owns SRP, account/address keys, local databases,
API transport, sync and selected-message decryption. The helper uses Proton's pinned HTML sanitizer and returns both sanitized markup
and bounded text. The selected body is rendered in a nonpersistent local WebKit
view with content scripts and automatic resource loading blocked. Links require
an explicit external-open confirmation. Plain text remains literal; a text view
is always available. See [Mail rendering](MAIL_RENDERING.md).

The session encryption key protects tokens/key secrets, not the entire Mail data
database. The pinned SDK persists decoded message bodies and metadata in ordinary
SQLite in the default build. An opt-in SQLCipher candidate keys new databases
and requests a saved first page before refresh. It refuses legacy profiles;
whole-profile migration and attachment protection remain incomplete. See
[the local storage review and release gate](LOCAL_STORAGE.md).

Sidebar and messages are bounded; selected
contents are decrypted on demand and session/selection epochs reject late replies.
Lock/close tears down the helper. Remote sign-out is acknowledged before clearing
the saved-session hint. Unsupported human verification/FIDO-only/password-change
states are explicit. Manual acceptance covers native sign-in and reading; live
delivery and account recovery remain acceptance gates. See [composer behavior](MAIL_COMPOSER.md).

`Resources/MailProtocol.json`, `Resources/MailHelper.lock` and
`patches/mail-core.patch` pin this independent Mail implementation. The small
opt-in patch exposes an existing module and disables logging/telemetry, with
no replacement cryptography. Original source/license notices are preserved.
[MAIL_NATIVE_SIGN_IN.md](MAIL_NATIVE_SIGN_IN.md) records build and acceptance gates.

The older Bridge implementation remains an advanced optional compatibility path
with literal-loopback verified TLS and confirmed plain-text SMTP composition.
It does not supply credentials to the direct client. External Bridge's process
and menu item remain part of that optional path's resource cost.

Drive is deliberately not represented as a working product in the UI. A future
adapter needs a public, redistributable native SDK/CLI, encrypted streaming and
conflict handling, and Finder/File Provider integration. A generic file browser
with download links would not fulfill that product's job.

## Native Mail attachments

The helper exposes listed attachment metadata and one bounded, sequential file
transfer at a time. Download requests belong to a disclosed message in the current
folder/conversation; uploads and removals belong to the current editing draft.
No file paths cross app IPC. The pinned SDK owns download/decryption, upload jobs,
quota refusal and draft send readiness. A narrow native export reads cache bytes
through the existing storage adapter, including the opt-in encrypted candidate.

Native file selection and drops read regular files through no-follow descriptors.
Reader Save writes a private, quarantined atomic export; Quick Look uses a private
temporary copy removed on dismissal, selection change and lock. Local editor text
survives attachment metadata refreshes. Unknown add/remove outcomes block another
attachment mutation or send until metadata is reconciled, without automatic replay.
See [attachment behavior and acceptance](MAIL_ATTACHMENTS.md).

## API stability

The Pass helper interface is pinned, not a promise that Proton's internal API is
stable. Schema tests and lockfiles make drift reviewable. Upgrade one revision at
a time; inspect auth, model, encryption and license changes before adapting it.

## Native notifications

`NativeNotifications` owns macOS permission, delivery, Dock badges and opaque
click tickets. Product stores remain independent; only the unlocked native Mail
store attaches a monitor. Its five-second reads consume an in-memory SDK queue,
not network polls or list diffs. The existing SDK event loop fetches server
changes on its configured interval (currently 60 seconds). The feature-gated
Mail patch records CREATE IDs after event transaction commit, then checks current
unread/import/label/category state before projecting bounded sender/subject
metadata. It does not alter cryptography or server writes. Both V5 and V6 hooks
are covered by synthetic SDK fixtures.

Settings and preview/lock behavior are described in [NOTIFICATIONS.md](NOTIFICATIONS.md).
OS delivery is injected for contract tests. Real app bundles install a retained
UserNotifications delegate before launch completes; command-line tests and
synthetic preview bundles never instantiate the native notification center.

## Calendar account and preview boundary

The suite lazily creates an independent Calendar store. Native week/month/agenda
views and an inline editor retain their state across product switches. Preview
events are synthetic and memory-only; lock clears visible and hidden state.
The bounded Calendar adapter owns an independent helper and Keychain session,
with explicit one-use account handoff from unlocked Mail or online Pass. All-day
civil dates use exclusive model ends; timed events use absolute instants.
Single-event writes verify owned-calendar/event signatures and perform a fresh
row comparison; they are not an atomic server revision condition. Preview events
remain memory-only and never start the account helper. See [Calendar scope](CALENDAR.md).

## Contacts Mail view

Contacts is a suite-rail view over `NativeMailStore`, with independently retained
selection/search and list/detail request epochs. It is part of Mail's account
boundary, not another product credential store. The pinned SDK supplies its
event-synced contact index and selected decrypted card fields through closed
read-only helper commands. The composer uses a draft-bound To/Cc/Bcc picker;
no contact writes or system address-book integration are enabled. See
[Contacts](CONTACTS.md) for storage and acceptance boundaries.
