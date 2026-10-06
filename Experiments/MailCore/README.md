# Direct native Mail core feasibility probe

Credential-free build experiment, not a working Mail client. No app bundle,
account sign-in, session database, Keychain item or background service is created.
The production app still uses the existing Bridge adapter.

The reference is ProtonMail/clients commit
`2ecb794dbc221384dc6d88840965ac144db301ad`, with `mail-uniffi` 0.168.2.
The original mirror remains unchanged. `prepare.py` copies it into the ignored
`.tools/mail-core-probe` directory, keeps the 83 publicly present workspace
members, and uses public crates.io instead of the internal Nexus proxy.
No missing dependencies are stubbed and no upstream Rust implementation changes.

The included `Cargo.lock` is the experiment's candidate dependency lock,
generated from this reduced workspace. It is **not** a new production dependency
or a claim that all dependency notices/redistribution rights have been reviewed.
The original monorepo lock is also copied as `Cargo.upstream.lock` for comparison.
The candidate retains the original package name/version/source records: 239
unused records are removed, with no new registry/Git package records added.

Run from the repository root, with the project's Rust toolchain:

```sh
python3 scripts/bootstrap.py --references
python3 Experiments/MailCore/prepare.py
bash -c 'source scripts/env.sh; cd .tools/mail-core-probe; cargo metadata --locked --no-deps --format-version 1 > ../mail-core-metadata.json'
bash -c 'source scripts/env.sh; cd .tools/mail-core-probe; cargo check --locked -p mail-uniffi'
bash -c 'source scripts/env.sh; cd .tools/mail-core-probe; cargo build --locked -p mail-uniffi --profile mail-macos-debug'
```

Preparing into an existing directory is refused; preserve its results before
making another probe. Cargo downloads public dependencies into the project-local
tool cache. No global packages, internal credentials or Proton account are needed.
These commands compile upstream code, so use them only for the pinned reviewed
reference. Do not run its login UI, TUI or account tests on a real mailbox.

## Recorded outcome, 2026-10-06

- Original workspace metadata: refused because the public mirror omits declared
  `project/account/rust/account-crux/Cargo.toml`, among other unrelated members.
- Reduced public workspace metadata: passed.
- Original lock with the reduced workspace: Cargo correctly refused `--locked`.
- Candidate lock: recorded separately here for reproducibility.
- Host-native `cargo check -p mail-uniffi`: passed (Apple Silicon, Rust 1.99).
- Native library linkage: passed with `--locked --profile mail-macos-debug`,
  producing an arm64 `.dylib` and static archive. The unoptimized build reports
  an oversized DWARF unwind-section warning; optimized build/performance checks
  remain. No binary is included in the app or published.

Even a successfully linked library does not prove that Proton accepts the future
Mail protocol identity, that authentication challenges work, that session storage
is secure, or that a mailbox can be decrypted and restored after restart. Before
account use, review the SDK's logging, telemetry, issue reporting and cache/key
storage and implement separate ProtonX Mail boundaries. See
[the integration decision](../../docs/MAIL_NATIVE_SIGN_IN.md).
