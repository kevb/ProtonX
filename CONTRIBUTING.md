# Contributing

Start with the README, architecture decisions and SECURITY.md. Small focused
issues/PRs are welcome. Keep native macOS behavior and product separation intact.
Use synthetic data in fixtures, screenshots and performance reports.

Build with Swift 6 and stable Rust. Run `swift test`, `scripts/test-bridge.sh`,
`scripts/test-helper.sh` for adapter changes, and `scripts/build-app.sh`.
Use the resulting app for keyboard-only and light/dark checks. Do not introduce
unit tests that only restate trivial view layout; test contracts, lifecycle races
and user-visible behavior. Error messages must never echo raw helper output.

A patch touching Proton code must preserve its copyright/license notices, remain
reviewable in `patches/pass-cli.patch`, and have an accompanying pinned-source
update and contract tests. Do not replace crypto, skip certificate verification,
or bypass Proton's account eligibility restrictions.

PRs should explain the problem, final behavior, validation, and remaining limits.
Review security-sensitive storage/login/clipboard changes separately. See the
roadmap for product scope. This project accepts external contributions directly
on GitHub; it does not inherit Proton's internal contribution workflow.
