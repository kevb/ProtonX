# Official-client gap analysis

Review date: 2026-10-06. Pass comes first. This review compares the current
ProtonX source with pinned official source and current primary documentation;
it is not a walkthrough of private accounts in the official apps. Implemented
features still need live interoperability checks. No account contents or secrets
belong in this document, screenshots, tests, or public issues.

## What should happen today

1. **Make desktop sign-in and session recovery dependable.** The morning handoff
   failed with HTTP 422/API 8004 before opening the account page. Synthetic,
   credential-free requests to both fork endpoints succeeded. Muon's normal
   request layer first creates an anonymous session; its public `from_fork`
   code flow explicitly omits that step. ProtonX now uses that existing flow for
   desktop login, preserving the original CLI path. Rebuild and verify a real
   handoff before calling this fixed. Then exercise first-vault setup, restart,
   local unlock, cancellation, expiry, sign-out and reauthentication. Direct
   password login remains experimental; its rejection has not been resolved.
2. **Prove a small complete Pass workflow and fix any bugs it exposes.** Use
   synthetic note/login records in the designated account: create, open, edit,
   refresh, trash, restore and verify from another client. Preserve fields not
   represented by the editor. Test locked/cancelled saves, lost acknowledgements,
   stale selection and errors without losing drafts. Confirm the filtered list
   and detail agree: one morning demo snapshot showed a Notes-only list beside
   a previously selected login detail; this needs a repeatable reproduction.
3. **Improve the everyday login editor.** Multiple website URLs, login notes on
   creation, TOTP setup/edit, and custom fields are more useful immediately than
   adding another product. Expose permissions and plan limits before presenting
   unavailable actions. Keep hidden fields hidden and unsupported fields intact.
4. **Reduce repeated work and surface sync state.** Each helper command starts
   a process and bootstraps event sync. Loading a snapshot calls capabilities,
   vault listing and then item listing separately for every vault. Profile that
   cost, then consider one bounded metadata-snapshot command with a single sync.
   Show refreshing/error/last-success states. Establish session recovery before
   adding periodic background work. Benchmark matched synthetic account sizes.
5. **Start a native AutoFill feasibility spike.** Use Apple's credential-provider
   extension APIs, a metadata-only identity index and an explicit unlock flow.
   Resolve extension signing, entitlements, sandbox and helper access before
   implementation. A website credential match must precede disclosure. Reuse
   Proton's existing passkey crypto when tackling passkeys later.

This is an ordered backlog, not a promise that every item fits in one day.
Authentication and a verified basic workflow are the first acceptance gates.

## Pass comparison

| Area | Official baseline | ProtonX today | Next action |
| --- | --- | --- | --- |
| Sign-in | Desktop account handoff; account verification | System authentication window plus experimental native prompts; live flow not yet established | First gate: verified login, setup and recovery; no CLI-eligibility workaround |
| Vault browsing and sync | Synced vault/item workspace | Native three-column UI, title search, explicit refresh; repeated helper startup/sync | Reliable snapshot, status, large-vault timing and cancellation |
| Item editing | Logins, notes, cards and other supported item forms; custom fields | Creates/edits login and note basics; reads several other kinds; URLs editable only at creation; one URL input | Complete login editor, then cards/identities/Wi-Fi/SSH forms |
| TOTP | Setup and use of two-factor secrets | Copy of an existing permitted code; no setup/edit UI | Synthetic enrollment fixture, URI validation, entitlement-aware editing; preserve server limits |
| Organisation | Vault management, moving items | Vault selection only; no create/rename/delete/move UI | Create/rename vaults and move items after permission-aware metadata |
| Permissions | Shared vaults and role-specific access | Swift vault model omits roles; SDK/server remain authoritative | Surface create/update/trash permissions and disable misleading actions |
| Offline | Paid desktop access to cached items | Upstream encrypted cache exists, but no supported offline UI | Read-only offline mode first; review unlock, expiry, cache freshness and entitlement policy |
| Autofill | Browser extensions, including Safari; paid desktop autotype | Copy/reveal plus optional global quick access | Native credential-provider spike; retain official browser extensions during transition |
| Passkeys | Existing Proton passkey support across clients | Counts only; cannot create or use passkeys | Separate extension integration and origin-bound tests; no new crypto |
| Attachments | Attach/open/save/manage files on supported paid plans | Counts only | Deferred until encrypted file handling, quota and safe temporary-file lifecycle are designed |
| History and recovery | Paid item history; Trash | Trash/restore; no history UI; no permanent deletion | Read-only item history and recovery before considering permanent deletion |
| Sharing and aliases | Vault sharing, secure links, hide-my-email aliases | Alias display; no sharing or alias creation | Later: invitations, roles and expiry handling through existing Proton implementations |
| Monitoring and administration | Pass Monitor and organisation features | No corresponding UI | Later; do not infer plan/organisation permissions from the absence of UI |
| Accounts | Account/session handling in official clients | One isolated Pass profile; no switcher | Explicit account separation and sign-out/recovery before multi-account support |

Official desktop functionality is documented in Proton's
[desktop guide](https://proton.me/support/how-to-use-proton-pass-desktop-app),
[macOS setup guide](https://proton.me/support/set-up-proton-pass-macos),
[autotype guide](https://proton.me/support/pass-autotype),
[attachment guide](https://proton.me/support/pass-file-attachments),
[sharing guide](https://proton.me/support/pass-share-vault), and
[passkey overview](https://proton.me/pass/passkeys).
Autofill in an official browser extension is a separate surface from the desktop
app. Availability is plan/platform dependent; do not treat every row as an
unconditional feature on every account.

## macOS and suite experience

| Area | Assessment and next step |
| --- | --- |
| Menu bar | One optional ProtonX item is implemented. Mail still needs external Bridge, which can retain its own item. Do not claim one icon for all Proton processes or change official-app settings automatically. Validate no-icon operation, narrow/notched displays and quick access. |
| Product structure | Keep separate Pass/Mail windows and sessions, with shared window commands and OS integration. This preserves each task's shape without multiplying tray items. Consider separate signed processes/sandboxes when extensions or privilege boundaries justify them. |
| Keychain and unlock | Keychain is already used, but local UI unlock is not a security audit or proof of authenticated-session recovery. Test genuine restart/unlock, screen lock, sleep, user switching and owned-clipboard clearing. Official macOS Pass already offers biometrics; Touch ID alone is not a differentiator. |
| Navigation | Complete keyboard-only search, selection, editing, Trash/restore and VoiceOver checks. Ensure native menus expose the same enabled actions as buttons. Clear stale details when filters/selection change. |
| Background behaviour | No automatic refresh/login item yet. Closing a window keeps the suite alive. Add opt-in launch at login only after recovery is reliable; a closed window must not trigger needless polling or leave an interactive helper running. |
| Performance | On-demand helpers avoid a permanently resident Chromium runtime, but repeated startup/sync may hurt latency and energy. Measure whole process sets with identical data, including Bridge. Existing unmatched idle snapshots establish no percentage improvement. |
| Distribution | Ad-hoc local builds only. Dependency-license review, Developer ID signing, notarization, update authenticity and corresponding source remain release gates. Do not release the vendored dependencies while licensing is unresolved. |

Apple documents the native integration surface in
[credential provider extensions](https://support.apple.com/guide/security/credential-provider-extensions-sec6319ac7b9/1/web/1)
and [ASCredentialProviderViewController](https://developer.apple.com/documentation/AuthenticationServices/ASCredentialProviderViewController).
This is a feasibility direction, not a working extension or approved entitlement.

## Mail and Drive

Proton's [official Mail desktop app](https://proton.me/support/mail-desktop-app)
provides the Mail/Calendar experience. ProtonX currently has only a small Bridge
client: 25 recent messages, limited plain-text MIME, single-recipient composition
and TLS verification. Mail lacks paging, thread view, reply/forward, read/unread,
archive/trash, mailbox search, attachments, drafts, notifications and Calendar.
The next useful Mail slice is paging + read/unread + reply, after a real Bridge
round trip and broader synthetic MIME coverage. Direct Mail auth would be a
separate integration project; it should not share the Pass session. Bridge's
[paid-plan requirement](https://proton.me/mail/bridge) remains part of this design.

Drive is already closely integrated with Finder: Proton documents a background
app, Finder folder, on-demand files, offline pinning and sync activity in its
[macOS guide](https://proton.me/support/drive-macos-guide). Replacing it with a
generic suite file browser would give up important macOS behaviour. Defer Drive
implementation; investigate the existing native core and File Provider architecture
before choosing an integration. A shared launcher/status surface is a possible
middle ground, but does not by itself replace or hide the official Drive item.

## Source anchors and validation scope

The reviewed official source is pinned in `upstream.lock.json` (WebClients
`0b1d912065235b251adc545c1d91cb615bfab73b`; Pass CLI
`7ae51e52818bca8df905988e4b149d43d31d4c83`). Useful anchors are:

- `applications/pass-desktop/src/lib/auth/interceptors.ts`: ordinary desktop
  browser/callback flow. ProtonX's SDK device-code handoff is a different flow;
  it must earn its own live validation.
- `packages/shared/lib/fetch/headers.ts` and desktop `src/lib/env.ts`: desktop
  compatibility identity; no claim of Proton affiliation.
- Pass CLI `pass-cli/src/main.rs`: per-command `bootstrap_event_sync`.
- Pass SDK `pass/src/permission/mod.rs`: existing permission checks.
- ProtonX `PassStore.loadSnapshot`, `PassService`, `PassModels.Vault` and
  `PassViews.ItemEditor`: actual native feature boundaries.

For test results see [VALIDATION.md](VALIDATION.md); for release/license and
performance boundaries see [LICENSE_REVIEW.md](LICENSE_REVIEW.md),
[PERFORMANCE.md](PERFORMANCE.md) and [SECURITY.md](../SECURITY.md).
