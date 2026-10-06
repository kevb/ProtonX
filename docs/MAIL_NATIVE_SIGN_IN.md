# Native Mail sign-in decision

Review date: 2026-10-06. The required product experience is **open Mail → enter
Proton username/password → complete any account challenge → inbox**. On restart,
restore Mail's own session with local unlock as appropriate. No separate Bridge
installation, generated mail-client password, ports or certificate import should
be required in the normal experience. Direct sign-in is not implemented today.

## Decision

Promote direct native Mail integration ahead of further Bridge feature expansion.
The current Bridge client is a developer prototype and an optional compatibility
path, not the intended consumer onboarding. Do not add a nonfunctional native
sign-in button or conceal Bridge settings behind a wizard and call that direct
Mail authentication. Pass remains independently usable while Mail is developed.

Preferred route: adapt Proton's existing Rust Mail SDK behind a narrow native
boundary and retain SwiftUI/AppKit for the interface. Keep Mail sessions, keys,
local databases and Keychain entries separate from Pass. Authentication success
is insufficient: Mail must unlock the account/address keys and decrypt a message.

## Evidence and upstream references

The newly reviewed reference is
[ProtonMail/clients at 2ecb794](https://github.com/ProtonMail/clients/tree/2ecb794dbc221384dc6d88840965ac144db301ad),
recorded in `upstream.lock.json`. The archived `ProtonMail/rust-mail` repository
points to this monorepo; do not treat the archived repository as the maintained
source. No Mail SDK is embedded in the ProtonX app yet.

Under `project/mail/rust/`:

- `account/account-uniffi/src/login/mod.rs`: `LoginFlow.login`, `submit_totp`,
  `submit_fido`, `submit_mailbox_password` and typed login/challenge states.
- `mail/mail-uniffi/src/mail/session.rs`: `create_mail_session`,
  `new_login_flow`, `to_user_session`, persisted-session restoration and the
  `OSKeyChain` boundary. Its constructor initializes logging; a privacy review
  is required before using it with any account, even with debug disabled.
- `mail/mail-uniffi/src/mail/mailbox.rs`: inbox/label mailbox constructors.
- `mail/mail-uniffi/src/mail/messages.rs`: message loading/body decryption and
  existing read/unread and label actions.
- `core/core-common/src/context.rs`: native desktop platform selection.
- Root `Cargo.toml`: `mail-macos` and `mail-macos-debug` profiles.

The official iOS source's README warns that its packaged SDK distribution is
internal. This prevents simply linking its missing prebuilt Swift package, but
does **not** establish that the public Rust Mail source cannot be built. The
existing macOS shell script also references an absent internal `rust-build`
directory and old paths. Test the public crates directly instead.

The pinned official Electron Mail implementation loads the Mail web client in
`applications/inbox-desktop/src/utils/view/viewManagement.ts`; copying that
window would not supply a native SwiftUI mailbox implementation.

## Alternatives considered

| Route | User experience | Tradeoff |
| --- | --- | --- |
| Public native Rust Mail SDK | Native sign-in, direct inbox and existing Proton crypto/sync | Preferred; source packaging, bindings, privacy, licenses and live protocol compatibility need proof |
| Proton Go API/crypto components used by Bridge | Native credentials and direct API access are possible | More session, key, sync and send integration to assemble; do not weaken Bridge product eligibility or reuse the Pass identity |
| Privately managed Bridge backend | Could automate client settings and offer native prompts | Still Bridge, with its own product limits, lifecycle, local transport and process costs; possible fallback, not proof of direct desktop parity |
| Embedded Mail website | Existing sign-in and broad feature coverage | Does not fulfill the requested native product interface |
| External Bridge plus manual settings | Existing prototype | Fails the intended normal onboarding |

## Build probe

`Experiments/MailCore/prepare.py` makes an isolated copy in `.tools`; it changes
no upstream source or production dependency. The sanitized mirror declares 161
workspace members but publishes only 83 of their manifests. Unmodified Cargo
metadata fails on the missing `account-crux` manifest, before compiling Mail.
The probe removes only unpublished workspace members and replaces the internal
crates.io Nexus mirror with public crates.io. Published Mail dependencies must
still resolve normally; no stubs or replacement cryptography are introduced.

Metadata then succeeds. Removing unpublished workspace members requires a new
candidate dependency lock: the original `--locked` build refuses the change.
Keep both locks for comparison. A successful check/build will establish only
native source feasibility, not functioning login, server acceptance, complete
redistribution rights or safe storage. See `Experiments/MailCore/README.md` for
commands and recorded outcomes.

The first host-native typecheck and library link passed. The reduced candidate lock removes 239
unused package records without introducing new registry/Git package records;
the existing resolved name/version/source records remain. This improves the
feasibility evidence beyond the original workspace metadata failure.

## First useful milestone and acceptance gates

1. Build/link the pinned public core for the host Mac, produce Swift bindings or
   a bounded private helper interface, and record the full dependency/license
   delta. The Mail SDK is AGPL-3.0-only; review combined-work obligations before
   production linkage or distribution. Do not silently change ProtonX licensing.
2. Implement native username/password, TOTP and second-mailbox-password states.
   Handle human verification and security-key requirements explicitly, with a
   supported secure fallback where needed. Preserve server product limits.
   Pin a reviewed Mail protocol identity independently of Pass; identify ProtonX
   honestly. Do not assume the Pass fork fix applies to Mail's login transport.
3. Fetch folders and a bounded inbox page and decrypt one selected synthetic
   message using the upstream core. Keep remote images/scripts disabled by
   default. Do not implement SRP or OpenPGP in Swift.
4. Persist/restore Mail's own session with reviewed Keychain/storage behavior;
   test restart, cancellation, local lock, expiry, revocation, sign-out and
   network recovery. Late results cannot reopen a locked/signed-out account.
5. Use synthetic public fixtures first, then an explicitly designated disposable
   account for sign-in/read/restart. Never use the primary mailbox as a development
   fixture or send messages without authorization.

Only after that working sign-in-to-inbox slice should we add Mail paging,
threading, reply/drafts, attachments, search and notifications. Measure the
complete process set and background activity; native code does not itself prove
a memory or energy reduction.
