#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROTONX_ROOT"
if pgrep -x ProtonX >/dev/null; then
  echo 'Quit ProtonX before rebuilding its app bundle.' >&2
  exit 1
fi
if [[ "${1:-}" != "--skip-helper" ]]; then scripts/build-helper.sh; fi
[[ -f upstream/pass-cli/target/release/pass-cli ]] || { echo 'Build the helper first.' >&2; exit 1; }
"$PROTONX_SWIFT" build --build-system native -c release
PROTONX_BIN_DIR="$("$PROTONX_SWIFT" build --build-system native -c release --show-bin-path)"
mkdir -p "$PROTONX_ROOT/build"
PROTONX_STAGE="$(mktemp -d "$PROTONX_ROOT/build/.app-stage.XXXXXX")"
trap 'rm -rf "$PROTONX_STAGE"' EXIT
PROTONX_BUNDLE="$PROTONX_STAGE/ProtonX.app"
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
# Replace the generated bundle only after signing succeeds. Do not overwrite
# executables mapped by an already-running app.
PROTONX_FINAL="$PROTONX_ROOT/build/ProtonX.app"
if [[ -e "$PROTONX_FINAL" ]]; then mv "$PROTONX_FINAL" "$PROTONX_STAGE/Previous.app"; fi
if ! mv "$PROTONX_BUNDLE" "$PROTONX_FINAL"; then
  if [[ -e "$PROTONX_STAGE/Previous.app" ]]; then mv "$PROTONX_STAGE/Previous.app" "$PROTONX_FINAL"; fi
  exit 1
fi
echo "$PROTONX_FINAL"
