# Local signatures and Keychain prompts

The build supports `PROTONX_SIGN_IDENTITY` (certificate name or SHA-1 fingerprint)
or an ignored `.tools/signing-identity` file containing the same value. Without
configuration it remains ad-hoc signed. The app and both helpers are signed;
helpers have fixed, independent identifiers. No certificate or private key is
committed, no Keychain ACL is broadened, and no signing identity is installed.
Local builds use no timestamp and are not a notarized distribution workflow.

For an available identity:

```sh
security find-identity -v -p codesigning
PROTONX_SIGN_IDENTITY='your certificate name' ./scripts/build-app.sh
```

Ad-hoc signatures bind identity to the executable's code hash. A certificate can
give successive builds the same designated requirement. Apple's
[code-signing note](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)
explains how Keychain tracks that requirement. Modern file-based Keychain also
checks partition membership; a stable requirement alone is not proof that an
updated locally signed executable will avoid authorization.

## Host validation, 2026-10-06

The existing local certificate on the development Mac is self-signed, despite
its name starting with “Developer ID Application”. It is not an Apple-issued
Developer ID certificate. The configured app/helpers passed strict signature
verification and have certificate-anchored requirements instead of code hashes.

`scripts/test-signing.sh` creates one explicitly synthetic item in
`org.kevb.ProtonX.Testing.Signing`. Interaction is disabled in the probe process:
it cannot ask for a Keychain password. Separate launches of the creating binary
read it successfully. An ad-hoc replacement is refused. A changed executable
signed with the same local certificate is also refused (`errSecAuthFailed`).
The probe restores the original executable and deletes its own synthetic item.
It returns nonzero if update continuity is unproven; this is an optional local
release diagnostic, not a required account-free CI test.

A manual Mail update check encountered another Keychain authorization prompt,
consistent with the failing continuity probe. Prompt-free update behavior has
not passed acceptance.

**Prompt-free helper updates have not passed the local signing probe**.
Retain the same build between launches and choose **Always Allow**, rather than
one-time Allow, when intentionally authorizing ProtonX's Keychain item. Existing
items made by an older signature may need initial authorization for a new build.
Do not delete account encryption keys to “fix” an authorization prompt.

An Apple-issued stable signing identity should be tested with this same probe
before promising update continuity. We do not add an undocumented partition-list
workaround, broad `apple-tool:` access, a universal trusted application, or a
temporary credential broker. Normal Touch ID/Mac-password local unlock remains
a separate protection and is deliberately retained.
