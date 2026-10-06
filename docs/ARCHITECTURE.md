# Architecture decisions

## Separate windows, shared integration

We considered four models:

| Model | Strength | Cost |
| --- | --- | --- |
| Entirely separate apps | Independent updates, quitting and permissions; familiar product identities | More Dock/menu-bar entries; duplicated settings, login/session scaffolding and helpers |
| One combined workspace | One process and installation; obvious product switching | Mail competes with vault tasks; password unlock can unnecessarily disrupt mail; larger failure/security boundary |
| Separate apps plus coordinator | Independent sandboxes with one menu-bar entry | IPC, coordinator lifecycle and version negotiation; the coordinator can become a hidden mandatory service |
| One suite, separate product windows | Shared OS integration with familiar task boundaries; no coordinator process | Shared process/address space and update cadence; closing a product isn't quitting an app |

**0.1 chooses one suite with separate product windows.** Pass and Mail have
independent sessions, state, unlock prompts and adapters. A shared menu-bar icon
is optional. Product views don't call each other's APIs. The navigation does not
turn the vault into a tab inside an email app. A future separately distributed
Pass or Mail binary can share ProtonXCore, but separate product processes and
sandboxing require another decision and tests, not merely changing a target name.

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
implementation reached a live workspace after user-driven authentication and
local unlock; remote writes and recovery still need validation.
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

The current Mail prototype delegates account authentication and encryption to a separately running
Proton Bridge. Its generated mail-client password is independent of the user's
main Proton password. The native view displays a bounded set of message headers
and fetches a selected message. Plain-text MIME bodies are decoded; HTML and
remote resources are not executed. SMTP composition uses encoded headers/body
and rejects control characters in addresses/subjects. This release does not
bundle or supervise Bridge. The additional Bridge process and its menu item are
part of the cost of this design and must be included in resource comparisons.

This is not the intended consumer onboarding. The next Mail milestone is native
Proton credentials/challenges followed by a decrypted inbox and session restore,
using Proton's existing Rust Mail core. Manual Bridge/server configuration remains
an optional compatibility path. [MAIL_NATIVE_SIGN_IN.md](MAIL_NATIVE_SIGN_IN.md)
records the reviewed upstream code, isolated build probe and acceptance gates;
direct Mail authentication is not implemented in the app yet.

Drive is deliberately not represented as a working product in the UI. A future
adapter needs a public, redistributable native SDK/CLI, encrypted streaming and
conflict handling, and Finder/File Provider integration. A generic file browser
with download links would not fulfill that product's job.

## API stability

The Pass helper interface is pinned, not a promise that Proton's internal API is
stable. Schema tests and lockfiles make drift reviewable. Upgrade one revision at
a time; inspect auth, model, encryption and license changes before adapting it.
