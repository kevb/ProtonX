# Pass reliability: automation and acceptance

Review date: 2026-10-07. Automated regression coverage uses synthetic data
and isolated test storage. No production vaults, account revocation or changes
to the Mac's network settings are needed.
Existing tests are evidence of local contracts, not full Proton interoperability.

## Coverage and next work

| Area | Existing evidence | Next automated checks |
| --- | --- | --- |
| Helper failure | `ProcessTests.swift` covers process deadlines/cancellation, sanitised failures, partial-output exits for reads/writes, fresh-process recovery and exited-helper prompt cancellation | SDK saved-session/key recovery and upgrade fixtures; never replay an unconfirmed write |
| Refresh/reconnect | `PassRecoveryTests.swift` covers first-load retry, retaining last-success data through failure, successful reconnect, atomic permission/capability replacement and no repeated sign-in | Independent-client event reconciliation and larger synthetic workloads |
| Edits/conflicts | Revision required/forwarded; native stale-revision guards; scripted conflict/unconfirmed edit blocks another write until refresh; manual fictional-login acceptance covers bidirectional desktop edits and conflict refusal | Broader unsupported-field round trips and independent-client event reconciliation |
| Trash restoration | Synthetic lifecycle and command-path restore/denial, lost acknowledgement, failed post-write refresh; manual fictional-login Trash/restore acceptance passed | Larger workloads and cross-client Trash reconciliation under interrupted refresh |
| Restart/session recovery | Synthetic saved-session/local-unlock and expiry tests; manual online quit/restart acceptance passed | Keychain continuity across rebuilds/upgrades and real server expiry/revocation interoperability |
| Encrypted offline browse | SQLCipher generation storage plus encrypted-session restore, wrong/missing keys, corruption, rotation, account/session binding, policy lease, saved-first/reconnect/lock races are synthetic-tested | Real-account disconnected restart and Keychain update continuity; larger-vault performance and managed-policy support |

Some process fixtures execute a real disposable child process; preview lifecycle
tests use an in-memory model and deliberately forbid account access. Neither
substitutes for testing Proton's server. Simulate network faults in a bounded
test transport or helper fixture rather than disconnecting the development machine.
Synthetic policy fixtures cover expiry/revocation; do not revoke real sessions
or change subscriptions to manufacture test conditions.

The first implementation slice now covers refresh/reconnect, fresh-helper
recovery and command-path conflict/restore failures. Its saved-session fixture is
a file-presence hint with scripted helper responses, not a decrypted Proton session.
Local unlock is injected only in these tests; normal builds use macOS user presence.
Invalidation is remembered in the current store; the UI adds no saved-file deletion.
Proton's SDK invalidation/cleanup remains unchanged. If a session hint remains, a
new app process must unlock and ask the SDK to restore again. Durable offline
browsing follows real session recovery and its separate storage/policy gates. Do not turn a failed
operation into an automatic write retry or queue: a lost acknowledgement can
mean the server accepted it. Keep editor drafts and require authoritative refresh
before further writes. Offline browsing starts read-only and respects authenticated
product and organisation policy, not an inferred local subscription flag.

## Small real-account acceptance pass

Account acceptance requires interactive authentication, macOS user-presence
prompts and any server-required challenges. Designated test-account validation
can exercise only clearly fictional test records, inspect the results through
an independent official client and report
the observed outcomes. Account access remains explicitly authorised and private
contents stay out of public tests, screenshots and logs.

1. Authenticate ProtonX and the official Proton Pass desktop app to the designated
   test account. Use the desktop app for record search/edit/Trash verification; the
   Safari extension is evaluated separately for website filling. Each client has its own session/local lock.
2. Create a fictional login with reserved example domains. Verify it in the
   other client; edit it there, refresh in ProtonX, and test a stale revision.
3. Trash and restore only that record; verify active/Trash membership after sync.
4. Restart ProtonX, perform local unlock when prompted, and verify the same
   record and session. Test cancellation without changing unrelated data.
5. For the saved-vault update, prove a fresh process can
   browse the permitted saved record while its test transport is unavailable,
   with clear freshness state and writes disabled; reconnect and reconcile.

Failures discovered here become synthetic regression cases where possible.
Passing local fixtures does not establish server interoperability, real account
expiry handling, or actual Safari filling. Record those as separate results.
A follow-up corrected the native edit guard to use Proton's `ItemState::Active`
wire value, with a real encrypted read-then-password-update mock-server contract.
The UI keeps a visible Refresh Vault action beside a blocked-write warning, even
when its error banner is dismissed. Genuine stale revisions and non-active states
remain refused. See [the Safari integration decision](CREDENTIAL_PROVIDER.md).
Manual account acceptance passed bidirectional edit/sync, conflict refusal,
Trash/restore and online quit/restart for a fictional login. This is limited manual
coverage, not automated real-account testing or coverage of all item types. Encrypted offline browsing now has synthetic storage/app coverage; its disconnected real-account acceptance is still pending.
