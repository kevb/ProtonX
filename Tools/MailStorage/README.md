# Mail storage candidate

AGPL-3.0-only. Opt-in SQLCipher connection initialization and single-database
conversion primitives for ProtonX's pinned Mail SDK. No replacement account crypto.

Read [the storage scope and unresolved gates](../../docs/LOCAL_STORAGE.md) before
using. Tests use only temporary synthetic fixtures; no installed profile or
Keychain item is opened. Run `scripts/test-mail-storage.sh` from the repository.

The helper refuses plaintext profiles. `upgrade_database` is not connected to a
user migration action and must not be used on a real profile yet. Profile-wide
crash recovery, existing send queues, older builds and attachment files require
additional work before activation. Default app builds remain unchanged.
