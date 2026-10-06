# Roadmap

See the [2026-10-06 official-client gap analysis](GAP_ANALYSIS.md) for the
ordered Pass-first work plan and acceptance gates. Sign-in and a verified
end-to-end workflow come before additional products.

## Next priorities (2026-10-06)

1. **Finish the secure-storage foundation already in progress.** The opt-in Mail
   candidate encrypts its databases and supports saved-first loading, but the
   normal app does not enable it. Complete whole-profile cutover/recovery,
   protect decrypted attachment/MIME files, preserve pending drafts/sends and
   prevent older builds reopening a migrated profile. Measure startup integrity
   checks before promising faster opening. See [the storage review](LOCAL_STORAGE.md).
2. **Make Pass dependable across launches and network failures.** Validate session
   recovery, edits/conflicts/Trash restoration and interoperability with another
   client. Then add an encrypted, policy-aware read-only item cache through Proton's
   existing storage layer, with useful freshness and recovery states. See the
   [automation and acceptance plan](PASS_RELIABILITY.md).
3. **Complete Mail's everyday workflow.** Validate actual send/reply delivery and
   enabled Gmail sending identities; add read/unread, archive/trash, threading and
   attachments. Preserve drafts and distinguish confirmed delivery from uncertain
   send outcomes.
4. **Polish suite navigation and installation.** Add a visible product switcher,
   establish reliable installed-app updates and signing/Keychain continuity, then
   provide **ProtonX Mail** and **ProtonX Pass** Spotlight launchers. Keep independent
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
  activation and attachment protection remain gates; see
  [the migration boundary](MAIL_STORAGE_MIGRATION.md).

These have synthetic/source validation. The user has also reported successful
live Pass login creation, sync and deletion, and native Mail sign-in/read access.
That does not establish broader edit/recovery interoperability, Mail delivery or
release readiness.

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
  implemented. The user has reported live sign-in and reading; verify restart,
  challenge/recovery flows and release licensing separately.
- Verify send/reply delivery, including enabled Gmail sending identities, on a
  designated test account. Do not infer successful delivery from composer UI.
- Threading, read/unread controls, archive/trash, attachments and richer MIME handling.
- Test interrupted sends, ambiguous delivery and draft recovery across upgrades.
- Retain Bridge as an optional prototype/compatibility path. Its lifecycle work
  is secondary to proving direct native Mail onboarding.

## Drive and packaging

- Evaluate Proton's supported native SDK/CLI and File Provider constraints.
- Decide separate process/sandbox packaging after proving the suite UX and IPC needs.
- Measure total memory/CPU (including Bridge and transient helpers) before publishing
  any reduction percentages.
- Add optional native Spotlight launchers named **ProtonX Mail** and **ProtonX Pass**
  that open the corresponding window in the shared app. Defer installation until
  builds can be reliably updated in Applications; document shared Quit/Dock/⌘Tab
  behavior. Pair them with a visible in-window product switcher.

## Local storage and faster opening

- Initial loading/failure and genuinely empty states are now distinct; existing
  content remains visible during refresh.
- Finish the opt-in encrypted Mail candidate before enabling it in normal builds:
  whole-profile migration/recovery, attachment/MIME file protection, old-build
  exclusion and SDK pending-send safety remain gates. See
  [the storage/startup review](LOCAL_STORAGE.md).
- Validate the candidate's saved-first loading through restart/offline recovery and
  measured cold/warm workloads. Accurate freshness, failure retention and stable
  selection have synthetic contracts; no measured startup speedup is established.
- Persist Pass item revisions through Proton's existing encryption layer, subject
  to product/organisation offline policy; start with read-only access.
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
