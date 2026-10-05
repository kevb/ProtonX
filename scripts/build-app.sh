#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROTONX_ROOT"
if [[ "${1:-}" != "--skip-helper" ]]; then scripts/build-helper.sh; fi
[[ -f upstream/pass-cli/target/release/pass-cli ]] || { echo 'Build the helper first.' >&2; exit 1; }
"$PROTONX_SWIFT" build --build-system native -c release
PROTONX_BIN_DIR="$("$PROTONX_SWIFT" build --build-system native -c release --show-bin-path)"
PROTONX_BUNDLE="$PROTONX_ROOT/build/ProtonX.app"
mkdir -p "$PROTONX_BUNDLE/Contents/"{MacOS,Helpers,Resources}
cp "$PROTONX_BIN_DIR/ProtonX" "$PROTONX_BUNDLE/Contents/MacOS/ProtonX"
cp upstream/pass-cli/target/release/pass-cli "$PROTONX_BUNDLE/Contents/Helpers/protonx-pass"
cp Resources/Info.plist "$PROTONX_BUNDLE/Contents/Info.plist"
cp LICENSE THIRD_PARTY_NOTICES.md upstream.lock.json "$PROTONX_BUNDLE/Contents/Resources/"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$PROTONX_BUNDLE/Contents/Resources/"; fi
# Local ad-hoc signatures. Distribution requires your own Developer ID and notarization.
codesign --force --sign - --options runtime "$PROTONX_BUNDLE/Contents/Helpers/protonx-pass"
codesign --force --sign - --options runtime "$PROTONX_BUNDLE"
codesign --verify --deep --strict "$PROTONX_BUNDLE"
echo "$PROTONX_BUNDLE"
