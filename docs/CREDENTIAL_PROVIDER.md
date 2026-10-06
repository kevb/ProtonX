# Native AutoFill feasibility

Decision date: 2026-10-06. Defer a ProtonX credential provider; keep it outside
the main app until its security and distribution boundaries are proven.
`Experiments/CredentialProvider` is a
compile-only macOS 14 API probe, not an installed extension. It cancels every
request and never publishes identities or returns passwords. There is no account
access, shared Keychain access, entitlement registration or credential IPC.

## Safari decision: use the standalone official extension

Proton describes its Safari extension as standalone in the
[macOS/Safari launch announcement](https://proton.me/blog/proton-pass-all-devices).
Its [setup guide](https://proton.me/support/pass-setup#Safari) installs **Proton Pass
for Safari** from the App Store and signs in through the browser toolbar. The
[current upstream build instructions](https://github.com/ProtonMail/WebClients/blob/main/applications/pass-extension/README.md)
package it as a separate Mac Catalyst app with a Safari Web Extension, rather
than the Electron desktop app. This is current upstream documentation, not a
change to ProtonX's pinned dependencies.

Read-only bundle inspection on the development Mac found both version 1.41.1:
`me.proton.pass.catalyst` with the contained
`me.proton.pass.catalyst.safari-extension`, and separately
`me.proton.pass.electron`. The extension has its own background service worker
and browser storage permissions. Installation was confirmed; Safari's enabled
state, current account and live filling were not inspected.

Keep the Safari wrapper installed. The intended combination is ProtonX for
native vault browsing/editing and the official extension for Safari filling,
autosave and supported browser passkeys. They sync through the same Proton
account; ProtonX does not share session credentials, local unlock state or a
Keychain group with the extension. A change appears after each client's sync;
locking or signing out of ProtonX does not lock or sign out the extension.

This removes an immediate requirement to implement another Safari extension.
A ProtonX OS credential provider for native-app/system surfaces is a separate,
optional future project; this check does not establish its platform coverage.
Before claiming end-to-end interoperability, verify a fictional test login's
create/edit/Trash/restore cycle through both clients in a designated test account.
Do not change installed extension permissions or access real vault contents as
part of synthetic validation. See [the reliability plan](PASS_RELIABILITY.md).

## What was verified

The installed Apple SDK exposes `ASCredentialProviderViewController`, system
service identifiers and user-interaction-required cancellation on the minimum
macOS 14 API surface. `scripts/test-credential-provider.sh` typechecks the native
controller with Swift 6 and warnings treated as errors. Twenty synthetic cases
exercise an intentionally conservative HTTPS/exact-origin candidate filter:
ports, subdomains, deceptive suffixes, userinfo, Unicode lookalikes and malformed
identifiers. A candidate match does not authorize disclosure. App identifiers
on newer SDKs are rejected by the probe.

Primary references: Apple's
[provider controller](https://developer.apple.com/documentation/authenticationservices/ascredentialproviderviewcontroller),
[identity store](https://developer.apple.com/documentation/authenticationservices/ascredentialidentitystore),
and the corresponding AuthenticationServices headers in the installed SDK.
The probe does not prove that Apple will register the extension, that a signing
profile grants its entitlements, or that every target browser supports it.

## Proposed boundary

1. A separately sandboxed credential-provider extension receives the OS request.
   Keep Pass/Mail sessions separate. Never give the extension direct access to
   the suite's whole Keychain or to the Mail profile.
2. An opt-in identity index holds only the minimum service identifiers, usernames
   and opaque item references required by Apple's API. These are sensitive metadata,
   too: enabling/indexing must explain the disclosure and removing an account must
   clear its identities. The existing batched vault snapshot deliberately has no
   usernames or passwords and must not become a bulk-secret export for indexing.
3. A narrow authenticated broker resolves a single selected Pass item. Validate
   the extension's signed identity and audit token, bounded request schema, account,
   request nonce and deadline. The main app's unlocked UI flag is insufficient;
   require a short-lived broker grant bound to the request and OS service origin.
4. Match before decrypting/returning credentials; recheck after unlock and before
   completing the system request. Production matching must respect Proton's URL
   modes, including `Never`, exact/prefix rules and edits made in other clients.
   The conservative experiment is not an implementation of those rules. Avoid
   handwritten registrable-domain matching; no suffix-based password disclosure.
5. While locked, request interaction. Cancel on screen lock, account change,
   revocation, request expiry or helper failure. Do not persist passwords in the
   identity index or an App Group file, route them through the clipboard, or allow
   unsolicited secret-bearing notifications.

An App Group and narrowly scoped Keychain access group may be appropriate for
metadata and extension/broker coordination. They require a separate review of
signed identities and provisioning. The current unsandboxed on-demand helper
cannot simply be copied into an extension and assumed to work. Developer ID,
notarization, licensing and corresponding-source gates remain applicable.

## Acceptance gates before embedding

- Register a signed extension on a disposable macOS account; demonstrate real
  host support and System Settings enable/disable without touching a primary vault.
- Prove locked/user-presence and caller-identity checks using synthetic credentials.
- Test cancellation/replay, origin change between selection and completion, denied
  URL modes, account switching and hostile/oversized IPC.
- Confirm metadata removal, sandbox/App Group permissions and no secret cache,
  logs, arguments, environment variables or plaintext temporary files.
- Verify retrieval/return with a designated disposable Proton vault and another
  client. Treat passkeys as a subsequent project using Proton's existing crypto.

If system/native-app integration is prioritised later, start with signed
registration and the broker prototype. Until then, retain the compile-only probe
and focus on Pass reliability; do not expose a non-functional AutoFill toggle.
