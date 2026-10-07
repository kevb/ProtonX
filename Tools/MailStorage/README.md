# Mail storage candidate

AGPL-3.0-only. A small profile guard shared by both Mail helpers, with an opt-in
SQLCipher engine and resumable database/attachment staging for the pinned Mail SDK.
No replacement account cryptography or production migration action.

Read [the storage scope](../../docs/LOCAL_STORAGE.md) and
[the migration boundary and recovery gates](../../docs/MAIL_STORAGE_MIGRATION.md)
before using. Tests use temporary synthetic fixtures; no installed profile or
Keychain item is opened. Run `scripts/test-mail-storage.sh` from the repository.

Both updated helpers refuse pending migrations. The normal helper also refuses
encrypted databases, without enabling SQLCipher in its build. Candidate startup
still refuses legacy plaintext profiles. `migration::stage_databases` retains
originals and prepares validated encrypted copies; it never activates them or
replays sends. `migration::stage_attachment_cache` adds encrypted copies of existing
attachment/MIME files and an encrypted source-path map, retaining originals and
checking both inventories on resume. Stored SDK paths are not rebased yet.
The older single-file `upgrade_database` primitive remains isolated
and must not be used on real profiles. Whole-profile cutover, cache path rebasing,
historical-build exclusion and actual send recovery remain activation gates.
