# Contributing

Start with the README, architecture decisions and SECURITY.md. Small focused
issues/PRs are welcome. Keep native macOS behavior and product separation intact.
Use synthetic data in fixtures, screenshots and performance reports.

Build with Swift 6 and stable Rust. Run `swift test`, `scripts/test-bridge.sh`,
`scripts/test-helper.sh` for Pass adapter changes, `scripts/test-mail-helper.sh`
for Mail adapter changes, and `scripts/build-app.sh`.
Use the resulting app for keyboard-only and light/dark checks. Do not introduce
unit tests that only restate trivial view layout; test contracts, lifecycle races
and user-visible behavior. Error messages must never echo raw helper output.

A patch touching Proton code must preserve its copyright/license notices, remain
reviewable in `patches/pass-cli.patch` or `patches/mail-core.patch`, and have an accompanying pinned-source
update and contract tests. Do not replace crypto, skip certificate verification,
or bypass server product permissions. Keep CLI eligibility in the CLI product
policy; the explicit desktop policy uses the pinned desktop account protocol.
Do not log or include account-fork URLs in reports: they contain one-use secrets.

PRs should explain the problem, final behavior, validation, and remaining limits.
Review security-sensitive storage/login/clipboard changes separately. See the
roadmap for product scope. This project accepts external contributions directly
on GitHub; it does not inherit Proton's internal contribution workflow.

## Documentation

Write public documentation for people evaluating, using or contributing to
ProtonX. Describe the current behavior, supported scope, limitations and next
steps. Keep implementation status separate from validation: distinguish automated
synthetic tests, manual account acceptance and outstanding release gates.

Avoid chat transcripts, personal development narration, references to “the user”
or an assistant, and temporary handoff instructions. Put dated technical evidence
in `docs/VALIDATION.md`; keep the README and roadmap current. Completed manual
checks should name the workflow and scope, without implying automated coverage
or independent security review. Do not remove genuine limitations for presentation.

## Live account validation

Normal builds and automated tests need no Proton account. For an explicitly
designated disposable account, authenticate through ProtonX, then run:

```sh
./scripts/test-account.sh prepare
./scripts/test-account.sh session
```

The session workflow checks synthetic note create/read/edit/Trash/restore in the
same local Pass profile and leaves one clearly named note in recoverable Trash.
Close or lock ProtonX before helper tests use that profile. Never use a primary
vault or publish account contents, credentials or session handoff URLs.

For experimental unattended direct-password testing, `setup` opens a native
secure credential form, `check` reports readiness, and `run` consumes the saved
test credential and removes it after the attempt, including failure. `clear`
removes it without testing. This tool is separate from the app bundle; see
[SECURITY.md](SECURITY.md) for its Keychain and authorization boundaries.
