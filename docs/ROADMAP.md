# Roadmap

See the [official-client gap analysis](GAP_ANALYSIS.md) for the
ordered Pass-first work plan and acceptance gates. Sign-in and a verified
end-to-end workflow come before additional products.

## Next priorities (2026-10-07)

1. **Finish the secure-storage foundation already in progress.** The opt-in Mail
   candidate encrypts databases and new attachment/MIME cache payloads and supports
   saved-first loading. The normal app does not enable it. Complete existing-cache
   path rebasing/activation, export audit, whole-profile cutover/recovery, preserve pending drafts/sends and
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
   undo and SDK conversation reading are implemented with synthetic/public upstream
   tests. Accept cross-client conversation behavior and add attachment viewing/sending.
   Preserve drafts and distinguish confirmed delivery from uncertain send outcomes.
4. **Accept the shared suite workspace.** One ProtonX window now provides Home,
   a labelled product rail, lazy Pass/Mail workspaces and a nonmodal Mail composer.
   Product switches preserve selection/search and unsaved draft contents. Native
   **ProtonX Mail** / **ProtonX Pass** Spotlight launchers select that product in
   the suite. Validate installed cold/warm routing, focus, minimum-OS/runtime and
   Keychain continuity. Keep product sessions separate and one optional menu-bar
   item; detachable windows remain later work.

Safari website AutoFill remains covered by the standalone official extension.
A ProtonX credential provider for system/native-app integration is optional later
work, not a daily-use release gate; see [the integration decision](CREDENTIAL_PROVIDER.md).

Repository presentation is backlogged below. Drive remains exploratory; prioritise
Pass and the shared macOS experience before expanding the suite.

## Completed native foundations

- Embedded Touch ID lock screens for Mail and Pass, foreground-only automatic
  activation, explicit password fallback and cancellation/retry states. Physical
  biometric and minimum-OS acceptance remain gates.
- Atomic metadata/Trash snapshot, permission-aware actions and last-success state.
- Native selection, filters, sorting, empty states and synthetic preview isolation.
- Login/note editing with multiple websites, notes, TOTP and text/hidden custom fields.
- Revision conflict protection, draft retention and acknowledged-save handling.
- Compile-only AutoFill feasibility contracts and offline storage review.
- Existing attachment/MIME staging with encrypted filename/path maps, verified
  payload copies and interruption recovery; original SDK references remain intact.
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
  SDK. Conversation grouping, cross-folder cards and individual-message mode are
  implemented with synthetic coverage; attachment UI and rich-text composition
  remain. Sanitized HTML reading preserves structure alongside a text fallback.
- Test interrupted sends, ambiguous delivery and draft recovery across upgrades.
- Retain Bridge as an optional prototype/compatibility path. Its lifecycle work
  is secondary to proving direct native Mail onboarding.

## Drive and packaging

- Evaluate Proton's supported native SDK/CLI and File Provider constraints.
- Decide separate process/sandbox packaging after proving the suite UX and IPC needs.
- Measure total memory/CPU (including Bridge and transient helpers) before publishing
  any reduction percentages.
- Native Spotlight launchers named **ProtonX Mail** and **ProtonX Pass**
  select the corresponding workspace in the shared app, alongside a labelled
  product rail and an opt-in verified Applications installer. Validate the
  installed routing and stable signing/Keychain behavior; see
  [the installation guide](DAILY_USE_UPDATE.md).

## Suite workspace

The initial implementation has one window with Home and a labelled Pass/Mail rail.
Product stores are created on first use and retained across switches. Startup
preferences select Home, the last product, Pass or Mail; explicit launcher routes
override them. Unsaved Mail content belongs to its Mail editor model and the
composer is nonmodal. Lock/close clears both product workspaces and unsaved drafts.
The following describes the broader direction and remaining acceptance, not a
claim that detached windows, Calendar or contextual inspectors are implemented.

- Provide a narrow product icon rail for Pass, Mail and, when implemented,
  Calendar/Drive. Give icons accessible names, tooltips, a clear selected state
  and native keyboard commands. Only expose usable products as navigation targets.
- Preserve each product's selected item/folder, search, scroll position and draft
  when switching products. Do not rebuild a store, relaunch a helper or refresh
  the server merely because a tab becomes visible.
- Move unsaved composer content out of sheet-local view state into an owned Mail
  draft model. A modal sheet currently prevents switching products: use an inline
  or independent composer that can remain open while consulting Calendar. Keep
  multiple composers and draft autosave as separate acceptance gates.
- Offer Home with large product icons on first launch and as a rail destination.
  Subsequent ordinary launches should restore the last workspace; allow a startup
  preference for Home or a particular product. Explicit product launches bypass Home.
- Preserve **ProtonX Mail** and **ProtonX Pass** Spotlight launchers and product
  links. Route them to the requested workspace or existing detached product
  window without briefly selecting a different product.
- Retain an explicit **Open in separate window** action for simultaneous work on
  multiple displays. Compare a workspace-first default with separate-window mode;
  avoid adding a large set of modes before the state/focus model is proven.
- Keep contextual tools separate from product navigation. A Calendar/Contacts
  inspector beside Mail may be useful later; do not overload the same icon with
  both changing the main workspace and opening a side panel.
- Instantiate products lazily, suspend unnecessary hidden rendering/polling and
  measure the whole process set. Preserving navigation state must not keep revealed
  Pass secrets alive across lock/sign-out or couple product authentication.
- Validate tab switches with unsaved drafts, independent lock/session expiry,
  detached windows, keyboard focus, VoiceOver, and cold/warm Spotlight routing.
  Benchmark first use, switching, idle memory and energy before claiming savings.

The official [side panel](https://proton.me/support/side-panel) opens contextual
Calendar, Contacts and account-security tools beside the current app. It is a
useful reference, but full product tabs are a separate ProtonX design proposal.

## Calendar (planned)

Calendar is not implemented. Treat it as a product/backend feasibility project,
not just another screen in the suite. Keep Pass reliability and everyday Mail
completion ahead of expanding the product set.

- Identify a source-pinned Proton implementation for Calendar authentication,
  key handling, encrypted event storage and sync; review licensing and helper
  contracts before choosing a native integration. Do not invent Calendar crypto
  or silently reuse a Mail/Pass session or export decrypted data to Apple Calendar.
- Start with read-only calendar/event browsing: week view, date navigation,
  Today, mini-month picker, time-zone display, multiple calendar visibility and
  colours. Consider day/month/agenda views after the core reader is usable.
- Add event creation/editing/deletion, recurrence, all-day events, time-zone/DST
  handling, reminders, attendees and invitation updates through Proton's existing
  implementation. Test recurring-event exceptions and concurrent edits explicitly.
- Connect Mail invitations and attachments to event inspection and RSVP actions.
  Preserve an unsaved Mail draft while switching to Calendar and returning.
- Evaluate shared/subscribed calendars, import/export and native notifications
  after basic event interoperability and recovery are established.
- Keep booking-page creation, availability, links and management as later,
  plan-aware functionality. See Proton's
  [appointment scheduling guide](https://proton.me/support/calendar-appointment-scheduling).

## Additional desktop parity backlog

These are missing capabilities or extensions to narrower implementations. A
visible feature in the official client is not evidence of its availability on
every plan. Screenshots used for design review must not be copied into public
assets; public captures and fixtures use synthetic content.

### Mail parity inventory

| Area | Missing capability or current limitation |
| --- | --- |
| Authentication/recovery | Human verification, FIDO-only/security-key login, password-change and wider account recovery/challenge flows. Existing native password/TOTP/second-password login and saved-session unlock must remain intact. |
| Attachments | List, download/open/preview and export attachments; upload/remove/drag-drop in drafts; embedded CID and inline images. Counts and SDK retention are not attachment management. |
| Composition | Forward; rich text (font/size/colour, emphasis, lists, alignment, links, quotations, inline images, clear formatting); plain-text option. Multiple/minimizable/pop-out drafts and automatic saving remain; initial nonmodal composing and tab-switch draft retention are implemented. |
| Sending controls | Undo Send, scheduled send with edit/cancel, read-receipt request/response, password-protected external messages and expiry. Preserve existing queued/confirmed/failed/unknown status handling. |
| Contacts | Contact book, picker/autocomplete, create/edit/delete, groups and group addressing, CSV/vCard import/export. To/Cc/Bcc and From selection already exist. |
| Search | Full-mailbox metadata/body search, recipient/date/attachment and other advanced filters. Current search covers only loaded subjects/senders, within the bounded message window. |
| Organisation | Star/unstar, snooze, arbitrary folder moves, label application, folder/label creation/edit/deletion/colours/subfolders. Existing custom folders can be browsed. |
| Bulk/conversation actions | Multi-selection, whole-thread actions, permanent deletion and empty Trash. Existing read/unread and Archive/Trash/Inbox actions and move undo target one message. Permanent deletion requires an explicit helper/policy review. |
| Spam and automation | Spam/phishing reporting, block/allow lists, simple filters/Sieve, automatic forwarding and out-of-office replies. |
| Inbox views | Category enable/manage controls and Primary/Social/Promotions/etc. views; mailing-list/newsletter management and unsubscribe controls. Availability can depend on rollout. |
| Reader privacy/images | Proton image proxy and tracker/pixel protection, tracking-link cleanup, persistent remote/embedded-image preferences and sender logos. Current raster-image opt-in fetches directly without Proton's proxy. |
| Message inspection | Full headers/original source, encryption/security indicators/details, external PGP key/trust/address-verification controls. Existing Proton encryption is not a missing feature. |
| Print/export/import | Print/PDF, individual EML export and native mailbox import/migration workflows. |
| Background/macOS | New-mail notifications, unread Dock badge, reliable background refresh, opt-in launch at login and default-mail-app/mailto registration. |
| Settings | Row/split layouts, density/composer size, explicit theme override, shortcut reference and broader keyboard actions; defaults/signatures/display names per sending identity; address/domain/linked-account setup or appropriate official settings links. Enabled Proton/custom-domain/Gmail identities already work. |
| Support/recovery | Product-scoped local-data reset with draft/uncertain-send safeguards, redacted diagnostic export, full settings/account/support entry points and storage/plan presentation. |
| Calendar/contextual tools | Calendar product and Mail invitation/RSVP integration; Calendar/Contacts inspectors; appropriate account/security links. See the staged Calendar plan above. |
| Optional writing assistance | Scribe-style drafting/proofreading/expand/shorten. Investigate availability, native integration and explicit local/server processing choices before selecting an implementation; do not silently substitute another provider. |

### Pass parity inventory

| Area | Missing capability or current limitation |
| --- | --- |
| Authentication/recovery | Broader native challenge/recovery and security-key flows; first-vault setup and expiry/revocation interoperability. Experimental native login and handoff exist; preserve CLI eligibility and desktop protocol policy. |
| Item editors | Create/edit cards, identities, Wi-Fi credentials, SSH keys and other supported custom item kinds. Login/note editing already exists; other kinds have limited viewing. |
| Custom fields | Editors for additional field types, including custom TOTP; current text/hidden editors preserve unsupported fields. |
| TOTP | Live code/countdown, QR import/scanning and raw-secret convenience. Primary TOTP setup/replacement/removal and code copy exist; preserve entitlement checks. |
| Generator | Length/character controls, memorable passphrases, standalone generator and strength feedback. The existing Generate action uses one default configuration. |
| Generated-password history | Separate from item versions: bounded two-week history in the desktop reference, explicit clearing and reviewed encrypted storage. |
| Search/sorting | Username/email, URL and note search; relevance, oldest-first and recently-used sorting. Current search is title-only with name/recently-changed ordering. |
| Vault management | Create/rename/delete, icon/colour, hiding/reordering, ownership controls and moving items between vaults. Permissions are respected but not administered. |
| Item organisation | Folders, pinning, duplication, bulk selection/move/Trash/restore, permanent deletion and empty Trash; review deletion policy before expanding the helper. Newer organisation features may be rollout-dependent. |
| Item history/recovery | View/compare previous revisions and restore an earlier version. Trash/restore already exists. |
| Attachments | Upload/download/open/preview/remove; encrypted file handling, quota and temporary-file lifecycle. Current UI exposes counts only. |
| Sharing | Invitations, member/role/access management, ownership transfer and secure item links with expiry/revocation. Shared-vault operation guards already exist. |
| Aliases | Create/manage/disable, forwarding mailboxes, custom domains, alias contacts and associated SimpleLogin controls. Existing aliases can be displayed. |
| Monitor | Weak/reused/breached passwords, missing 2FA, dark-web alerts and per-item monitoring exclusions. |
| Import/export | Native import, plain/encrypted exports and migration workflows with explicit disclosure controls. |
| Desktop integrations | Auto-Type and SSH-agent UI; quick access currently opens the ordinary Pass workspace. System/native-app credential provider remains optional, not installed. |
| Passkeys | Detailed view/management and native credential-provider operations. Current counts/preservation do not provide operations; browser use remains covered by the separate official extension. |
| Lock/preferences | PIN configuration, enable/change/reset extra password, configurable clipboard expiry and broader preferences/favicon/localisation/theme controls. Existing extra-password challenges and embedded Touch ID/macOS password unlock are supported. |
| Access tokens | Management through the appropriate pinned Proton protocol and product policy; never put tokens in logs, argv or environment. Desktop helper policy currently excludes CLI automation/PAT commands. |
| Offline/background | Broader policy-aware offline functionality and continuous refresh; current saved vault is read-only, personal-paid-policy limited, maximum 24 hours, excluding attachments and offline TOTP generation. No blind write replay. |
| Account/support | Plan/storage display, account/support/mobile-app links and appropriate organisation/SSO/admin settings access. A dedicated account switcher requires explicitly isolated product profiles; server restrictions must remain authoritative. |

### Shared release and account tools

- Developer ID signing/notarized downloads, authenticated automatic updates and
  source-compliant releases; minimum-OS/accessibility and measured resource usage.
- Full localisation, consistent themes and opt-in launch-at-login preferences.
- Account recovery/emergency access, wider security settings and business
  administration can initially use official account-site links; distinguish these
  web account tools from native product functionality.
- Safari browser autofill/autosave and browser passkeys remain with the independent
  official extension; duplicating it is not a suite release gate.
- Existing threading, sending/reply, Trash restoration and session recovery are
  implementations with separate validation gates, not wholesale missing features.

Reference baselines: Proton's [Mail desktop guide](https://proton.me/support/mail-desktop-app),
[Pass desktop guide](https://proton.me/support/how-to-use-proton-pass-desktop-app),
[side-panel guide](https://proton.me/support/side-panel) and pinned upstream source
in `upstream.lock.json`. Product settings and capabilities remain plan-dependent.

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
