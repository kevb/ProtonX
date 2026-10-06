# Pass reliability: automation and acceptance

Decision date: 2026-10-06. Most implementation and regression testing can proceed
without user input. Use synthetic data and isolated test storage; no production
vaults, account revocation or changes to the Mac's network settings are needed.
Existing tests are evidence of local contracts, not full Proton interoperability.

## Coverage and next work

| Area | Existing evidence | Next automated checks |
| --- | --- | --- |
| Helper failure | `ProcessTests.swift` covers process deadlines/cancellation, sanitised failures, partial-output exits for reads/writes, fresh-process recovery and exited-helper prompt cancellation | SDK saved-session/key recovery and upgrade fixtures; never replay an unconfirmed write |
| Refresh/reconnect | `PassRecoveryTests.swift` covers first-load retry, retaining last-success data through failure, successful reconnect, atomic permission/capability replacement and no repeated sign-in | Independent-client event reconciliation and larger synthetic workloads |
| Edits/conflicts | Revision required/forwarded; native stale-revision guards; scripted conflict/unconfirmed edit blocks another write until refresh; user reports successful bidirectional desktop edits and a passed conflict test | Broader unsupported-field round trips and independent-client event reconciliation |
| Trash restoration | Synthetic lifecycle and command-path restore/denial, lost acknowledgement, failed post-write refresh; user reports live Trash/restore passed | Larger workloads and cross-client Trash reconciliation under interrupted refresh |
| Restart/session recovery | Synthetic saved-session/local-unlock and expiry tests; user reports live quit/restart passed | Keychain continuity across rebuilds/upgrades and real server expiry/revocation interoperability |
| Encrypted offline browse | [Storage review](OFFLINE_DESIGN.md) exists; a durable item cache is not implemented | Add read-only persistence through Proton's existing encryption/storage layer; test wrong/missing keys, corruption, rotations, account isolation, policy expiry and lock races |

Some process fixtures execute a real disposable child process; preview lifecycle
tests use an in-memory model and deliberately forbid account access. Neither
substitutes for testing Proton's server. Simulate network faults in a bounded
test transport or helper fixture rather than disconnecting the user's machine.
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

User participation is limited to authentication, macOS user-presence prompts and
any server-required challenges that automation cannot satisfy. After that,
designated test-account validation can exercise only clearly fictional test
records, inspect the results through an independent official client and report
the observed outcomes. Account access remains explicitly authorised and private
contents stay out of public tests, screenshots and logs.

1. Authenticate ProtonX and the official Proton Pass desktop app to the designated
   test account. Use the desktop app for record search/edit/Trash verification; the
   user's Safari extension does not provide searchable vault browsing. Safari
   filling is a separate follow-up. Each client has its own session/local lock.
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
A follow-up corrected the native edit guard to use Proton's `ItemState::Active`
wire value, with a real encrypted read-then-password-update mock-server contract.
The UI keeps a visible Refresh Vault action beside a blocked-write warning, even
when its error banner is dismissed. Genuine stale revisions and non-active states
remain refused. See [the Safari integration decision](CREDENTIAL_PROVIDER.md).
The user subsequently reported the bidirectional edit/sync, conflict, Trash/restore
and quit/restart acceptance steps passed. This is live user-observed evidence for
the fictional login, not automated real-account testing or coverage of all item
types. Encrypted offline browsing remains unimplemented.
