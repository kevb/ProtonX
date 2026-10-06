# Official-client gap analysis

Review date: 2026-10-06. Pass comes first. This review compares the current
ProtonX source with pinned official source and current primary documentation;
it is not a walkthrough of private accounts in the official apps. Implemented
features still need live interoperability checks. No account contents or secrets
belong in this document, screenshots, tests, or public issues.

## Progress after the UX pass

- Native sidebar selection now uses macOS list selection. Changing collection,
  vault or title search clears a hidden selection and its details immediately.
  Type filters, counts, sorting, distinct empty states and account actions work
  in the synthetic preview.
- Login/note forms now include login notes, multiple editable websites, TOTP
  setup/replacement/removal and text/hidden custom field edits. Unchanged setup
  and unsupported fields remain intact. Editing is bound to the opened item's
  revision; a changed revision is refused before writing.
- One bounded metadata snapshot replaces capabilities + vault list + one item
  helper per vault. Active items, Trash, create/update/trash permissions and plan
  capabilities are loaded atomically. This reduces helper starts, not all server
  requests. The UI shows last-success/failure state and disables writes after an
  unconfirmed save or failed refresh until a successful refresh.
- Synthetic UI and contract tests cover create/edit/validation errors/Trash/restore,
  native selection, concealed custom fields, permission denial, unsupported-field
  preservation and an acknowledged save followed by failed refresh.
- [Offline storage review](OFFLINE_DESIGN.md) found that cached keys/settings do
  not constitute a persisted item vault. [AutoFill feasibility](CREDENTIAL_PROVIDER.md)
  now includes a checked native API probe and conservative origin tests; no
  ProtonX extension is installed and no credential disclosure is implemented.
  Safari filling can use the separate official extension; its installed wrapper
  was confirmed on this Mac. See the updated integration decision.
- The visual pass adds adaptive lavender/indigo surfaces, grouped rounded detail
  cards and clearer Edit/Create actions. Native selection and keyboard controls
  remain. The user reported successfully creating, syncing and deleting a live
  test login; no private contents were inspected by the agent.

The next acceptance gates remain designated disposable-account CRUD verified
from another client, restart/recovery and large-vault measurements. A ProtonX
credential provider is optional future system/native-app work; use the standalone
official extension for Safari. [The reliability plan](PASS_RELIABILITY.md) separates
existing synthetic coverage from remaining automation and live checks.
Primary-account screenshots were used only as layout references; their contents
were not added to the project.

## What should happen today

1. **Make desktop sign-in and session recovery dependable.** The morning handoff
   failed with HTTP 422/API 8004 before opening the account page. Synthetic,
   credential-free requests to both fork endpoints succeeded. Muon's normal
   request layer first creates an anonymous session; its public `from_fork`
   code flow explicitly omits that step. ProtonX now uses that existing flow for
   desktop login, preserving the original CLI path. The corrected local build
   reached a connected vault workspace after user authentication and macOS local
   unlock, with creation enabled and no error alert. Then exercise first-vault setup, restart,
   local unlock, cancellation, expiry, sign-out and reauthentication. Direct
   password login remains experimental; its rejection has not been resolved.
2. **Prove a small complete Pass workflow and fix any bugs it exposes.** Use
   synthetic note/login records in the designated account: create, open, edit,
   refresh, trash, restore and verify from another client. Preserve fields not
   represented by the editor. Test locked/cancelled saves, lost acknowledgements,
   stale selection and errors without losing drafts. Synthetic regression tests
   and native sidebar checks now keep the filtered list and detail consistent;
   the morning Notes-filter/stale-login issue is reproduced by a contract test
   and fixed. Confirmed-write/failed-refresh warnings also survive navigation.
3. **Improve the everyday login editor.** Multiple website URLs, login notes on
   creation, TOTP setup/edit, and custom fields are more useful immediately than
   adding another product. Expose permissions and plan limits before presenting
   unavailable actions. Keep hidden fields hidden and unsupported fields intact.
4. **Reduce repeated work and surface sync state.** The batched snapshot is now implemented. Each helper command starts
   a process and bootstraps event sync. The original snapshot called capabilities,
   vault listing and then item listing separately for every vault. One bounded
   metadata-snapshot helper now handles that work with one bootstrap.
   Show refreshing/error/last-success states. Establish session recovery before
   adding periodic background work. Benchmark matched synthetic account sizes.
5. **Verify interoperability with the standalone official Safari extension.**
   Use a fictional login in a designated test account after both clients sign in.
   Check create/edit/Trash/restore sync and independent local lock/sign-out behavior.
   Keep the extension's wrapper installed. Defer the ProtonX credential-provider
   spike to optional system/native-app work; the compile-only probe is retained.

This is an ordered backlog, not a promise that every item fits in one day.
Authentication and a verified basic workflow are the first acceptance gates.

## Pass comparison

| Area | Official baseline | ProtonX today | Next action |
| --- | --- | --- | --- |
| Sign-in | Desktop account handoff; account verification | Corrected system handoff and local unlock reached a live vault; native password prompts remain experimental | Finish setup/restart/recovery coverage; no CLI-eligibility workaround |
| Vault browsing and sync | Synced vault/item workspace | Native three-column UI, title search, sorting, atomic metadata/Trash snapshot and sync status | Large-vault timing, reconnect and cancellation |
| Item editing | Logins, notes, cards and other supported item forms; custom fields | Login/note editor with notes, multiple URLs and text/hidden custom fields; revision-bound saves; other kinds readable | Live editor interoperability, then cards/identities/Wi-Fi/SSH forms |
| TOTP | Setup and use of two-factor secrets | Permitted code copy and concealed setup/replacement/removal UI | Live enrollment round trip; preserve server limits |
| Organisation | Vault management, moving items | Vault selection only; no create/rename/delete/move UI | Create/rename vaults and move items after permission-aware metadata |
| Permissions | Shared vaults and role-specific access | Create/update/trash flags surfaced; UI + native SDK guards; server remains authoritative | Shared-role interoperability and item-share edge cases |
| Offline | Paid desktop access to cached items | Persisted key/settings cache; item cache only process-local; last-loaded interruption state | Persist encrypted item revisions; read-only offline policy and recovery tests |
| Autofill | Browser extensions, including Safari; paid desktop autotype | Copy/reveal, optional global quick access and compile-only credential-provider probe | Use the standalone official Safari extension; defer a ProtonX system/native-app provider |
| Passkeys | Existing Proton passkey support across clients | Counts only; cannot create or use passkeys | Retain official extension for supported browser passkeys; direct native use is deferred; preserve unsupported fields |
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
| Menu bar | One optional ProtonX item is implemented. Direct Mail needs no external Bridge; the optional compatibility path can retain Bridge’s own item. Do not claim one icon for all Proton processes or change official-app settings automatically. Validate no-icon operation, narrow/notched displays and quick access. |
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
provides the Mail/Calendar experience. ProtonX now packages a direct native Mail
core with credentials/TOTP/second-password states, separate session restoration,
folders, bounded paging and selected-message decryption. The normal experience
has no Bridge/server settings. The user reported real sign-in and reading.
A native composer now supports new/reply/reply-all, available From identities,
draft saving and queued/confirmed/failed/unknown send states. Linked-Gmail
sender selection has synthetic coverage; real delivery and recovery remain
unverified. Human verification and FIDO-only states are unsupported; threading,
read/unread, archive/trash, file upload/viewing and push UI remain gaps. See
[the native Mail decision](MAIL_NATIVE_SIGN_IN.md) and
[composer references and Gmail acceptance tests](MAIL_COMPOSER.md).
The advanced Bridge compatibility path retains its separate
[paid-plan requirement](https://proton.me/mail/bridge).

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
  `ItemEditor`: actual native feature boundaries.

For test results see [VALIDATION.md](VALIDATION.md); for release/license and
performance boundaries see [LICENSE_REVIEW.md](LICENSE_REVIEW.md),
[PERFORMANCE.md](PERFORMANCE.md) and [SECURITY.md](../SECURITY.md).
