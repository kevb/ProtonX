# Mail database migration preparation

Status: experimental database-set staging, disabled in the normal app. No account
profile is converted by startup, no migration UI exists, and no cutover is exposed.
Read [the storage review](LOCAL_STORAGE.md) and [Security](../SECURITY.md).

## Implemented boundary

`Tools/MailStorage` separates a small, database-independent profile guard from its
opt-in SQLCipher engine. Both updated helper variants hold the same profile lock
before SDK initialization and retain that lock through OS process termination.
This avoids an early unlock while default SDK pool workers are still detached.
A normal helper refuses encrypted databases or an
unsupported format marker, avoiding the SDK's rename/rebuild recovery path.
Neither helper opens a profile containing `.storage-migration`, even if it is
empty, damaged, a dangling symlink or fully prepared. Refusals are typed; no raw
paths, SQL, database contents or keys enter diagnostics.

`migration::stage_databases` requires a held guard and an in-process storage key.
It performs no Keychain calls or network requests. Its output is an encrypted
copy of each discovered account/user database, not an activated Mail profile.

1. Inventory plaintext databases under `sessions` and `users`, refusing symlinks,
   hard links, special files and unsupported paths. Fingerprint database/WAL data;
   refuse nonempty rollback journals rather than attempting recovery. WAL SHM read
   marks are ephemeral and are not treated as persistent message data.
2. Create a private `.storage-migration` directory (0700), an encrypted key-check
   database and a bounded, versioned recovery manifest (0600). The key-check binds
   even a plan with zero completed exports to its original key. The manifest
   contains relative paths, file hashes, lengths and progress; never the key or
   message/draft content.
3. Export each database using SQLCipher's established export API from a read-only
   source connection. SQLite includes committed WAL rows. Keep originals and their
   data journals intact; do not force a source checkpoint or copy plaintext into
   staging. Preserve schema, indexes/triggers, application/user versions and rows.
4. Validate and sync the encrypted output, atomically rename it to a reserved
   stage file, sync the staging directory, then persist progress with the same
   write/sync/rename sequence. Source changes during export stop preparation.
5. Recheck the complete source inventory before recording `prepared`. Resume by
   verifying the original fingerprints, key-check and every acknowledged output.
   An export interrupted before progress acknowledgement can be recreated from
   its unchanged source. A missing/damaged acknowledged output, changed source,
   wrong key or unsupported manifest requires explicit recovery and is retained.

Temporary encrypted exports and manifest files interrupted by process death remain
in the private staging directory. Resume never treats them as account databases,
never deletes the original profile and never dispatches the draft/send queue.
Staging requires space for a second database set; no low-disk success guarantee or
physical power-loss guarantee follows from process-crash tests.

## State and recovery behavior

| State | Helpers | Preparation |
| --- | --- | --- |
| Plaintext, no migration directory | Normal helper may open; candidate refuses | May inventory and stage |
| Pending / interrupted | Both refuse before Keychain/SDK | Resume only with unchanged source and original key |
| Prepared | Both still refuse | Revalidate; retain originals and exports |
| Wrong key, changed source, invalid/missing manifest or completed export | Both refuse while marker exists | Stop; retain files for explicit recovery |
| Encrypted profile without a pending marker | Normal helper refuses | Candidate still applies its encrypted preflight |

Removing a marker is not a supported recovery action. No production abort/cutover
workflow is shipped; tests use disposable directories that are deleted only by
the synthetic fixture owner after assertions.

## Attachment cache adapter (2026-10-06)

The opt-in candidate now writes newly cached attachment/embedded-MIME payloads
into atomic SQLCipher blob containers. The SDK cache hit/copy paths and calendar
invite parser decrypt them in memory. Generic filenames replace original names
on disk, with names retained in encrypted metadata. There is no native attachment
export endpoint; SDK file paths in this candidate refer to ciphertext containers.

Synthetic tests exercise the real SDK store/read/copy path and validate wrong keys,
corruption, empty/bounded data, replacement, permissions, links and plaintext
absence. Temporary/published files have mode 0600; rollback journals stay in memory.
The helper configures its key before SDK startup. Unkeyed upstream fixtures retain
upstream behavior. The normal app does not enable this feature. Startup inventories this cache,
refuses legacy names/links before Keychain access, and validates candidate payloads
before SDK construction. A remaining cache or format marker prevents creation of
a replacement storage key when databases are missing. Full cache validation adds
work to startup; its cost has not been benchmarked.

Existing files and absolute cache paths have not been migrated/rebased. Remaining
file APIs, staging and sender-image paths need an activation audit. These new-write
contracts do not establish whole-profile upgrade or queued-send recovery safety.
SQLCipher uses its [documented database/key APIs](https://www.zetetic.net/sqlcipher/sqlcipher-api/).

## Activation gates that remain

- Protect attachment/embedded-MIME file caches and account for their absolute
  stored paths; copying encrypted database rows alone does not relocate files.
- Define whole-profile cutover, interrupted-cutover recovery, backup retention
  and management of existing plaintext copies/journals. Do not promise secure
  erasure on SSD/APFS or through existing backups.
- Prevent historically older helpers that do not honor the lock/markers from
  opening the profile. The new guard coordinates updated builds only.
- Test genuine SDK draft/send replay and ambiguous delivery across migration.
  Preserved opaque fixture bytes in SDK queue tables are not a delivery proof.
- Provide native upgrade/recovery UI, isolated Keychain integration tests, schema
  compatibility rules, disk-space failure coverage and measured startup costs.
- Independently review the implementation before using an installed account.

## Validation

Run `scripts/test-mail-storage.sh` for isolated encrypted engine/SDK contracts and
candidate startup refusals. `scripts/test-mail-helper.sh` also exercises normal
helper refusals without requesting Keychain credentials.

The migration tests terminate a child process without cleanup at six durable
transitions: initial manifest, each of two exports, each progress acknowledgement
and the prepared marker. Resume must recover all stages while retaining originals.
Further fixtures cover wrong keys before any export, committed WAL rows, changed
sources/new databases, damaged/missing stages, malformed/traversing manifests,
symlink/hard-link destinations, permissions and absence of synthetic plaintext
markers in staging. A pinned SDK-schema fixture preserves decoded body, draft
references, opaque action-queue bytes and the complete schema without dispatch.

The implementation uses SQLCipher's documented
[export and key APIs](https://www.zetetic.net/sqlcipher/sqlcipher-api/).
