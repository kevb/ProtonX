#!/usr/bin/env bash
# Explicit local test; no account service, ACL relaxation or keychain UI.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROTONX_ROOT"
PROTONX_TEST_IDENTITY="${PROTONX_SIGN_IDENTITY:-}"
if [[ -z "$PROTONX_TEST_IDENTITY" && -f .tools/signing-identity ]]; then
  IFS= read -r PROTONX_TEST_IDENTITY < .tools/signing-identity
fi
[[ -n "$PROTONX_TEST_IDENTITY" && "$PROTONX_TEST_IDENTITY" != - ]] || { echo 'Configure a local signing certificate before this optional test.' >&2; exit 1; }
PROTONX_TEST_ACCOUNT="synthetic-signature-regression-$(uuidgen)"
PROTONX_TEST_STAGE="$(mktemp -d "$PROTONX_ROOT/.tools/signing-test.XXXXXX")"
trap 'if [[ -x "$PROTONX_TEST_STAGE/original" ]]; then cp "$PROTONX_TEST_STAGE/original" "$PROTONX_TEST_STAGE/first"; "$PROTONX_TEST_STAGE/first" remove "$PROTONX_TEST_ACCOUNT" >/dev/null 2>&1 || true; fi; rm -rf "$PROTONX_TEST_STAGE"' EXIT
"$PROTONX_SWIFT"c Tools/SigningValidation/main.swift -o "$PROTONX_TEST_STAGE/first"
"$PROTONX_SWIFT"c -DPROTONX_SIGNING_SECOND Tools/SigningValidation/main.swift -o "$PROTONX_TEST_STAGE/second"
codesign --force --sign "$PROTONX_TEST_IDENTITY" --timestamp=none --identifier org.kevb.ProtonX.Testing.Signing "$PROTONX_TEST_STAGE/first"
codesign --force --sign "$PROTONX_TEST_IDENTITY" --timestamp=none --identifier org.kevb.ProtonX.Testing.Signing "$PROTONX_TEST_STAGE/second"
cp "$PROTONX_TEST_STAGE/second" "$PROTONX_TEST_STAGE/untrusted"
codesign --force --sign - --identifier org.kevb.ProtonX.Testing.Signing "$PROTONX_TEST_STAGE/untrusted"
cp "$PROTONX_TEST_STAGE/first" "$PROTONX_TEST_STAGE/original"
"$PROTONX_TEST_STAGE/first" create "$PROTONX_TEST_ACCOUNT"
"$PROTONX_TEST_STAGE/first" read "$PROTONX_TEST_ACCOUNT"
cp "$PROTONX_TEST_STAGE/untrusted" "$PROTONX_TEST_STAGE/first"
"$PROTONX_TEST_STAGE/first" refuse "$PROTONX_TEST_ACCOUNT"
cp "$PROTONX_TEST_STAGE/second" "$PROTONX_TEST_STAGE/first"
"$PROTONX_TEST_STAGE/first" read "$PROTONX_TEST_ACCOUNT"
"$PROTONX_TEST_STAGE/first" remove "$PROTONX_TEST_ACCOUNT"
echo 'Rebuilt signed code retained noninteractive access; ad-hoc replacement was refused.'
