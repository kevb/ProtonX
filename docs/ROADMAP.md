# Roadmap

See the [official-client gap analysis](GAP_ANALYSIS.md) for the
ordered Pass-first work plan and acceptance gates. Sign-in and a verified
end-to-end workflow come before additional products.

## Next priorities (2026-10-07)

1. **Finish the secure-storage foundation already in progress.** The opt-in Mail
   candidate encrypts databases and new attachment/MIME cache payloads and supports
   saved-first loading. The normal app does not enable it. Complete existing-file
   migration/rebasing, export/staging audit, whole-profile cutover/recovery, preserve pending drafts/sends and
   prevent older builds reopening a migrated profile. Measure startup integrity
   checks before promising faster opening. See [the storage review](LOCAL_STORAGE.md).
2. **Finish Pass offline acceptance.** An encrypted, policy-aware read-only cache
   is implemented through Proton's storage layer, with synthetic restart, network
   failure, reconnect and locking coverage. Manual fictional-login acceptance covers
   cross-client editing/sync, conflict refusal, Trash/restore and online restart. Validate real disconnected restart,
   update Keychain continuity and broader item types. See the
   [automation and acceptance plan](PASS_RELIABILITY.md).
3. **Complete Mail's everyday workflow.** Validate actual send/reply delivery and
   enabled Gmail sending identities. Read/unread, Archive/Trash/Inbox and SDK move
   undo are implemented with synthetic/public upstream tests; add threading and
   attachments. Preserve drafts and distinguish confirmed delivery from uncertain
   send outcomes.
4. **Accept installed suite navigation.** A visible product switcher, window-aware
   keyboard commands, verified atomic app installation and **ProtonX Mail** /
   **ProtonX Pass** Spotlight launchers are implemented. Synthetic UI checks cover
   cold/warm routing and minimized/closed windows. Complete minimum-OS/runtime
   checks and update Keychain continuity. Keep independent
   product windows/sessions and the optional single shared menu-bar item.

Safari website AutoFill remains covered by the standalone official extension.
A ProtonX credential provider for system/native-app integration is optional later
work, not a daily-use release gate; see [the integration decision](CREDENTIAL_PROVIDER.md).

Repository presentation is backlogged below. Drive remains exploratory; prioritise
Pass and the shared macOS experience before expanding the suite.

## Completed native foundations

- Atomic metadata/Trash snapshot, permission-aware actions and last-success state.
- Native selection, filters, sorting, empty states and synthetic preview isolation.
- Login/note editing with multiple websites, notes, TOTP and text/hidden custom fields.
- Revision conflict protection, draft retention and acknowledged-save handling.
- Compile-only AutoFill feasibility contracts and offline storage review.
- Experimental Mail encrypted database candidate and resumable database-set staging,
  with original files retained and startup guards in both updated helpers. Profile
  activation, existing-cache migration and the full file API audit remain gates; see
  [the migration boundary](MAIL_STORAGE_MIGRATION.md).

Automated coverage uses synthetic fixtures and public upstream tests. Manual
fictional-login acceptance covers Pass creation, cross-client editing/sync,
conflict refusal, Trash/restore and online restart; Mail sign-in and reading have
manual acceptance coverage. Broader recovery, Mail delivery and release readiness
remain separate gates.

## Before a daily-use Pass release

- Validate the new desktop protocol backend on non-CLI-eligible accounts,
  preserving the original CLI product policy and server product limits.
- Disposable-account desktop-fork interoperability and cancellation/recovery tests.
- Resolve direct SRP rejection (HTTP 422/API 8004); TOTP/two/extra-password tests.
- Session invalidation, revoked key, expired account and network recovery tests.
- Cross-client sync with the official Safari extension, including preservation of
  unsupported passkey and website-matching fields during native edits. ProtonX
  system AutoFill and direct passkey/security-key use remain optional follow-ons.
- Attachments, sharing, identities/cards/Wi-Fi creation/editing, vault management.
- Offline browse with reviewed local locking and recovery behavior.
- Large vault performance and schema fixture upgrade coverage.
- Developer ID signing, notarization, source-compliant releases and security review.

## Mail

- **Required onboarding: native Proton sign-in → decrypted inbox → session
  restoration.** No manual server settings in the normal experience. See
  [the direct Mail core decision and acceptance gates](MAIL_NATIVE_SIGN_IN.md).
- Native Mail core, private IPC, native authentication UI, separate session storage,
  paged reader, composer/reply, sending-identity selection and draft handling are
  implemented. Manual account acceptance covers sign-in and reading; verify restart,
  challenge/recovery flows and release licensing separately.
- Verify send/reply delivery, including enabled Gmail sending identities, on a
  designated test account. Do not infer successful delivery from composer UI.
- Read/unread, Archive/Trash/Inbox and move undo are implemented through the pinned
  SDK; threading, attachment UI and rich-text composition remain. Sanitized HTML
  reading now preserves structure alongside a text fallback.
- Test interrupted sends, ambiguous delivery and draft recovery across upgrades.
- Retain Bridge as an optional prototype/compatibility path. Its lifecycle work
  is secondary to proving direct native Mail onboarding.

## Drive and packaging

- Evaluate Proton's supported native SDK/CLI and File Provider constraints.
- Decide separate process/sandbox packaging after proving the suite UX and IPC needs.
- Measure total memory/CPU (including Bridge and transient helpers) before publishing
  any reduction percentages.
- Native Spotlight launchers named **ProtonX Mail** and **ProtonX Pass**
  open the corresponding window in the shared app, alongside a visible
  product switcher and an opt-in verified Applications installer. Validate the
  installed routing and stable signing/Keychain behavior; see
  [the installation guide](DAILY_USE_UPDATE.md).

## Local storage and faster opening

- Initial loading/failure and genuinely empty states are now distinct; existing
  content remains visible during refresh.
- Finish the opt-in encrypted Mail candidate before enabling it in normal builds:
  whole-profile migration/recovery, existing attachment/MIME file migration, old-build
  exclusion and SDK pending-send safety remain gates. See
  [the storage/startup review](LOCAL_STORAGE.md).
- Validate the candidate's saved-first loading through restart/offline recovery and
  measured cold/warm workloads. Accurate freshness, failure retention and stable
  selection have synthetic contracts; no measured startup speedup is established.
- Pass encrypted read-only revisions are now persisted through Proton's layer
  with conservative entitlement/lease checks. Complete the disconnected-account
  acceptance in [OFFLINE_DESIGN.md](OFFLINE_DESIGN.md).
- Measure time to first list and selected detail on matching synthetic cold/warm
  workloads. Storage migration, wrong keys, corruption and lock races are gates.

## Repository presentation (backlog)

Build a polished public showcase after the core screens and navigation settle.
Use fictional synthetic content rather than redacting real account screenshots.

Existing building blocks: an original app icon, adaptive Pass design colours,
isolated synthetic Pass/Mail preview windows, login/note editors, Mail reader and
composer/reply scenes, and a forced-light preview build.

- Enrich the synthetic demo set with consistent fictional vaults, items, mail
  conversations and timestamps. Use reserved example domains and clearly dummy
  credentials; previews must never read installed account data or deliver mail.
- Provide repeatable scenes for Pass browsing/login/note editing, Mail inbox/reader/
  reply, and suite navigation/settings. Show supported behavior; label candidate
  or planned features explicitly.
- Add deterministic light and dark capture configurations, fixed window sizes,
  consistent selection and a capture guide. Check small GitHub display sizes,
  readability and accessibility; exclude desktop clutter and notifications.
- Prepare a compact README gallery with captions/alt text, a hero image and a
  matching GitHub social preview. Keep source assets and regeneration instructions
  in the repository, with the app revision recorded for each capture set.
- Retain independent ProtonX branding, asset attribution and license notices.
  Publish the showcase only when it accurately represents the available build.
