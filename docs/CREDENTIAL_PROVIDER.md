# Native AutoFill feasibility

Decision date: 2026-10-06. Keep AutoFill outside the main app until its security
and distribution boundaries are proven. `Experiments/CredentialProvider` is a
compile-only macOS 14 API probe, not an installed extension. It cancels every
request and never publishes identities or returns passwords. There is no account
access, shared Keychain access, entitlement registration or credential IPC.

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

The next useful work is the signed registration and broker prototype, not an
AutoFill toggle that cannot yet deliver credentials safely.
