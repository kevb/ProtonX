# Official-client gap analysis

Review date: 2026-10-07. This compares ProtonX's implemented behavior with pinned
official source and the linked product documentation. Implementation, automated
synthetic coverage and manual account acceptance are separate evidence categories.
The [roadmap](ROADMAP.md) tracks priorities; [validation](VALIDATION.md) records
technical results. Use synthetic content in public tests and screenshots.

## Current progress

- Native Pass selection, type/vault filters, title search, sorting and empty
  states keep the list and detail consistent. Login/note forms support multiple
  websites, notes, TOTP and text/hidden custom fields; unsupported fields are
  preserved and edits are bound to the selected revision.
- One bounded metadata snapshot loads vaults, active items, Trash, permissions
  and plan capabilities atomically. It reduces helper starts, not every server
  request. Unknown write outcomes require authoritative refresh before another
  attempt; failed saves retain drafts.
- Manual fictional-login acceptance covers creation, bidirectional editing/sync
  with the official desktop app, stale-revision refusal, Trash/restore and online
  quit/restart. Automated recovery contracts cover reconnect, helper failure,
  permission changes, cancellation and session invalidation. Broader item types,
  real server revocation and Keychain continuity across upgrades remain gates.
- Encrypted Pass saved-first/read-only browsing is implemented for eligible
  personal paid accounts with synthetic storage, policy and lock coverage.
  Disconnected real-account restart and matched startup benchmarks remain pending.
- Mail supports native sign-in, message reading, compose/reply, draft handling and
  selected-message actions. Manual acceptance covers sign-in and reading; live
  send/reply delivery and account recovery remain pending. Secure Mail storage and
  migration are release blockers in ordinary builds.
- Separate windows, a visible product switcher, front-window keyboard commands
  and native Spotlight launchers share one optional menu-bar item. Synthetic UI
  checks cover cold/warm routing and restoring minimized or closed windows.
- Safari website filling remains with the official standalone extension. The
  compile-only ProtonX credential-provider probe has no credential disclosure or
  installed extension. Native-app/system integration is optional future work.

## Priorities

1. Complete Mail secure-storage migration and recovery before enabling cached
   browsing in normal builds. Preserve pending drafts/sends and refuse old builds
   opening migrated profiles.
2. Finish disconnected Pass acceptance, upgrade/Keychain continuity, real session
   expiry/revocation and broader unsupported-field round trips.
3. Verify Mail new-message/reply/reply-all delivery, sending identities and draft
   recovery from another client; accept conversation interoperability and add
   attachment viewing/sending.
4. Extend permission-aware Pass editors and vault management, with independent
   client verification and draft/conflict safeguards.
5. Complete accessibility/minimum-OS checks, matched performance measurements,
   dependency review, signing and notarization before binary distribution.

## Pass comparison

| Area | Official baseline | ProtonX today | Next action |
| --- | --- | --- | --- |
| Sign-in | Desktop account handoff; account verification | Corrected system handoff and local unlock reached a live vault; native password prompts remain experimental | First-vault setup, challenge handling and real expiry/revocation; preserve CLI product policy |
| Vault browsing and sync | Synced vault/item workspace | Native three-column UI, title search, sorting, atomic metadata/Trash snapshot and sync status | Large-vault timing, reconnect and cancellation |
| Item editing | Logins, notes, cards and other supported item forms; custom fields | Login/note editor with notes, multiple URLs and text/hidden custom fields; revision-bound saves; manual cross-client login editing and conflict acceptance; other kinds readable | Broader field interoperability, then cards/identities/Wi-Fi/SSH forms |
| TOTP | Setup and use of two-factor secrets | Permitted code copy and concealed setup/replacement/removal UI | Live enrollment round trip; preserve server limits |
| Organisation | Vault management, moving items | Vault selection only; no create/rename/delete/move UI | Create/rename vaults and move items after permission-aware metadata |
| Permissions | Shared vaults and role-specific access | Create/update/trash flags surfaced; UI + native SDK guards; server remains authoritative | Shared-role interoperability and item-share edge cases |
| Offline | Paid desktop access to cached items | SQLCipher revisions, saved-first loading and read-only browsing; personal paid plans only, maximum 24-hour lease; synthetic recovery tested | Disconnected real-account acceptance, Keychain update continuity, larger-vault benchmarks and managed-policy support |
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
| Distribution | Local builds with ad-hoc or configurable local signing; no notarized release. Dependency-license review, Developer ID signing, notarization, update authenticity and corresponding source remain release gates. Do not release the vendored dependencies while licensing is unresolved. |

Apple documents the native integration surface in
[credential provider extensions](https://support.apple.com/guide/security/credential-provider-extensions-sec6319ac7b9/1/web/1)
and [ASCredentialProviderViewController](https://developer.apple.com/documentation/AuthenticationServices/ASCredentialProviderViewController).
This is a feasibility direction, not a working extension or approved entitlement.

## Mail and Drive

Proton's [official Mail desktop app](https://proton.me/support/mail-desktop-app)
provides the Mail/Calendar experience. ProtonX now packages a direct native Mail
core with credentials/TOTP/second-password states, separate session restoration,
folders, bounded paging and selected-message decryption. The normal experience
has no Bridge/server settings. Native sign-in and reading have manual acceptance coverage.
A native composer now supports new/reply/reply-all, available From identities,
draft saving and queued/confirmed/failed/unknown send states. Linked-Gmail
sender selection has synthetic coverage; real delivery and recovery remain
unverified. Read/unread, Archive/Trash/Inbox and move undo are implemented with
synthetic coverage. Human verification and FIDO-only states are unsupported;
SDK conversation grouping and expandable cross-folder cards have synthetic
coverage. File upload/viewing and push UI remain gaps. See
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
  its account acceptance is recorded separately in [Pass reliability](PASS_RELIABILITY.md).
- `packages/shared/lib/fetch/headers.ts` and desktop `src/lib/env.ts`: desktop
  compatibility identity; no claim of Proton affiliation.
- Pass CLI `pass-cli/src/main.rs`: per-command `bootstrap_event_sync`.
- Pass SDK `pass/src/permission/mod.rs`: existing permission checks.
- ProtonX `PassStore.loadSnapshot`, `PassService`, `PassModels.Vault` and
  `ItemEditor`: actual native feature boundaries.

For test results see [VALIDATION.md](VALIDATION.md); for release/license and
performance boundaries see [LICENSE_REVIEW.md](LICENSE_REVIEW.md),
[PERFORMANCE.md](PERFORMANCE.md) and [SECURITY.md](../SECURITY.md).
