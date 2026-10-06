# Pass reliability: automation and acceptance

Decision date: 2026-10-06. Most implementation and regression testing can proceed
without user input. Use synthetic data and isolated test storage; no production
vaults, account revocation or changes to the Mac's network settings are needed.
Existing tests are evidence of local contracts, not full Proton interoperability.

## Coverage and next work

| Area | Existing evidence | Next automated checks |
| --- | --- | --- |
| Helper failure | `ProcessTests.swift` covers process deadlines, cancellation, private challenges and sanitised failures | Exit/EOF during reads and writes, then successful fresh-helper recovery; no leaked pending prompts |
| Refresh/reconnect | `PassStoreTests.swift` distinguishes initial loading, failure and confirmed empty; acknowledged writes retain failed-refresh warnings across navigation | Fail then reconnect; preserve last-success data, clear uncertainty only after successful sync, restore permissions atomically |
| Edits/conflicts | `PassTests.swift` requires a revision and forwards it; existing native guards refuse stale revisions | Concurrent synthetic revision changes, draft retention, unsupported-field preservation and uncertain acknowledgement without automatic retry |
| Trash restoration | Synthetic preview create/edit/Trash/restore lifecycle clears secrets on lock; permission-aware commands are implemented | Command-path restoration with server-shaped fixtures, denied writes, interrupted restore, stale selection and authoritative refresh |
| Restart/session recovery | Private authentication handoff and process cancellation have contracts | Isolated synthetic saved-session lifecycle, expired/revoked-session failures, cancellation, local unlock and fresh helper after restart |
| Encrypted offline browse | [Storage review](OFFLINE_DESIGN.md) exists; a durable item cache is not implemented | Add read-only persistence through Proton's existing encryption/storage layer; test wrong/missing keys, corruption, rotations, account isolation, policy expiry and lock races |

Some process fixtures execute a real disposable child process; preview lifecycle
tests use an in-memory model and deliberately forbid account access. Neither
substitutes for testing Proton's server. Simulate network faults in a bounded
test transport or helper fixture rather than disconnecting the user's machine.
Synthetic policy fixtures cover expiry/revocation; do not revoke real sessions
or change subscriptions to manufacture test conditions.

The first implementation slice is refresh/reconnect and fresh-helper recovery,
then command-path conflict/restore failures. Durable offline browsing follows
session recovery and its separate storage/policy gates. Do not turn a failed
operation into an automatic write retry or queue: a lost acknowledgement can
mean the server accepted it. Keep editor drafts and require authoritative refresh
before further writes. Offline browsing starts read-only and respects authenticated
product and organisation policy, not an inferred local subscription flag.

## Small real-account acceptance pass

User participation is limited to authentication, macOS user-presence prompts and
any server-required challenges that automation cannot satisfy. After that,
designated test-account validation can exercise only clearly fictional test
records, inspect the results through an independent official client and report
the observed outcomes. Account access remains explicitly authorised and private
contents stay out of public tests, screenshots and logs.

1. Authenticate both ProtonX and the standalone official Safari extension to the
   designated test account. They have independent sessions and local locks.
2. Create a fictional login with reserved example domains. Verify it in the
   other client; edit it there, refresh in ProtonX, and test a stale revision.
3. Trash and restore only that record; verify active/Trash membership after sync.
4. Restart ProtonX, perform local unlock when prompted, and verify the same
   record and session. Test cancellation without changing unrelated data.
5. Once encrypted offline storage is implemented, prove a fresh process can
   browse the permitted saved record while its test transport is unavailable,
   with clear freshness state and writes disabled; reconnect and reconcile.

Failures discovered here become synthetic regression cases where possible.
Passing local fixtures does not establish server interoperability, real account
expiry handling, or actual Safari filling. Record those as separate results.
See [the Safari integration decision](CREDENTIAL_PROVIDER.md).
