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
- Pinned Proton Pass helper: upstream Rust CLI with a small explicit patch.
  Retains Proton's encryption, SRP/authentication, account checks and sync.
  All secret-bearing create/update data uses stdin. Native authentication is a
  private line-oriented challenge protocol, independent of terminal control.

No permanent Pass helper, browser engine, WebView, Electron or JavaScript runtime
is loaded. Helpers start on demand. Commands serialize to avoid racing encrypted
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
a checked script. The app never disables upstream CLI account eligibility.

## Mail and Drive

Mail delegates account authentication and encryption to a separately running
Proton Bridge. Its generated mail-client password is independent of the user's
main Proton password. The native view displays a bounded set of message headers
and fetches a selected message. Plain-text MIME bodies are decoded; HTML and
remote resources are not executed. SMTP composition uses encoded headers/body
and rejects control characters in addresses/subjects. This release does not
bundle or supervise Bridge. The additional Bridge process and its menu item are
part of the cost of this design and must be included in resource comparisons.

Drive is deliberately not represented as a working product in the UI. A future
adapter needs a public, redistributable native SDK/CLI, encrypted streaming and
conflict handling, and Finder/File Provider integration. A generic file browser
with download links would not fulfill that product's job.

## API stability

The Pass helper interface is pinned, not a promise that Proton's internal API is
stable. Schema tests and lockfiles make drift reviewable. Upgrade one revision at
a time; inspect auth, model, encryption and license changes before adapting it.
