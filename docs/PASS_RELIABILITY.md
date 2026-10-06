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
| Edits/conflicts | Revision required/forwarded; native stale-revision guards; scripted conflict/unconfirmed edit blocks another write until refresh, then loads the newer revision | Real concurrent-client revision changes; broader unsupported-field round trips |
| Trash restoration | Synthetic demo lifecycle plus command-path restore/denial, lost acknowledgement, acknowledged restore with failed refresh and authoritative reconciliation | Designated-account round trip verified through the official extension |
| Restart/session recovery | Two new stores over an isolated synthetic session hint require local unlock; denied/late unlock does not start the helper; expired read/write/restore sessions clear data and require sign-in | Real SDK encrypted-session restore, Keychain continuity and server expiry/revocation interoperability |
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
