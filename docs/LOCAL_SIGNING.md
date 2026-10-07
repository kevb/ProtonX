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

## Local Apple Development signing

For builds used on your own Mac, Xcode can create an **Apple Development**
certificate through a free Personal Team. In Xcode Settings → Accounts, select
your account and Personal Team, open Manage Certificates, and create Apple
Development. Account access and Apple's agreements must be completed by the
developer. Paid Developer ID distribution and notarization are separate workflows.

Find the certificate with `security find-identity -v -p codesigning`. Configure
its SHA-1 fingerprint locally so builds select that exact identity:

```sh
mkdir -p .tools
printf '%s\n' 'YOUR_CERTIFICATE_SHA1' > .tools/signing-identity
./scripts/test-signing.sh
./scripts/build-app.sh --install
```

Quit ProtonX before installation. The same configuration signs the app, both
product helpers and Spotlight launchers. Keep it across updates; no personal
identity is committed. The portable build default remains ad-hoc signed.

If signing reports an incomplete certificate chain, check for the matching
[Apple WWDR intermediate](https://developer.apple.com/help/account/certificates/wwdr-intermediate-certificates).
Apple Development uses G3. Obtain missing intermediates from Apple's linked PKI
site and use normal system trust; do not add custom trust overrides. Authorizing
`codesign` to use the signing private key is separate from authorizing a product
helper to read its session encryption key.

These builds do not embed provisioning profiles or request restricted
entitlements. Certificate expiration and free provisioning-profile expiration
are different constraints. Check your certificate's actual expiration in Xcode
or Keychain Access. Certificate renewal, revocation, team changes and adding
restricted entitlements require renewed validation; the continuity probe does
not test them.

On the first launch after changing signing identities, existing session keys may
need one Keychain authorization for the new helper. Choose **Always Allow** when
intentionally approving that helper, then validate reopening and a subsequent
update. Never delete encryption keys or broaden their ACLs to avoid the prompt.
Touch ID/Mac-password local unlock remains a separate protection.

## Synthetic continuity validation, 2026-10-07

An Apple-issued Apple Development identity from a free Personal Team passed
`scripts/test-signing.sh` on the development Mac. The original executable created
and reread its synthetic item without interaction. A changed executable signed
with the same certificate read that item without interaction, while an ad-hoc
replacement with the same identifier was refused. The test deleted the item.
The certificate inspected for this test expires one year after issuance.

This establishes continuity for the isolated synthetic probe on this host.
It does not establish migration of existing product keys, certificate renewal,
operation after expiry, or acceptance on other Macs. Contributors should run the
probe with their own certificate before relying on prompt-free rebuilds.

## Earlier self-signed validation, 2026-10-06

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

**The self-signed certificate failed the local signing probe**.
Retain the same build between launches and choose **Always Allow**, rather than
one-time Allow, when intentionally authorizing ProtonX's Keychain item. Existing
items made by an older signature may need initial authorization for a new build.
Do not delete account encryption keys to “fix” an authorization prompt.

An Apple-issued stable signing identity should be tested with this same probe
before promising update continuity. We do not add an undocumented partition-list
workaround, broad `apple-tool:` access, a universal trusted application, or a
temporary credential broker. Normal Touch ID/Mac-password local unlock remains
a separate protection and is deliberately retained.
