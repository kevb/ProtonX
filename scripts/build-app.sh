#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROTONX_ROOT"
PROTONX_PREVIEW=false
PROTONX_STAGE_UPDATE=false
PROTONX_UPDATE_NAME="ProtonX Update"
PROTONX_SKIP_HELPER=false
PROTONX_INSTALL=false
PROTONX_SWIFT_OPTIONS=()
for PROTONX_OPTION in "$@"; do
  case "$PROTONX_OPTION" in
    --preview) PROTONX_PREVIEW=true ;;
    --preview-light) PROTONX_PREVIEW=true; PROTONX_SWIFT_OPTIONS=(-Xswiftc -DPROTONX_DESIGN_LIGHT) ;;
    --stage-update) PROTONX_STAGE_UPDATE=true ;;
    --stage-update=*)
      PROTONX_STAGE_UPDATE=true
      PROTONX_UPDATE_NAME="${PROTONX_OPTION#--stage-update=}"
      if [[ -z "$PROTONX_UPDATE_NAME" || "$PROTONX_UPDATE_NAME" == */* || "$PROTONX_UPDATE_NAME" == .* ]]; then echo 'Use a simple app name for the staged update.' >&2; exit 1; fi
      ;;
    --install) PROTONX_INSTALL=true ;;
    --skip-helper) PROTONX_SKIP_HELPER=true ;;
    *) echo "Unknown build option." >&2; exit 1 ;;
  esac
done
PROTONX_APP_NAME=ProtonX
PROTONX_EXECUTABLE=ProtonX
if $PROTONX_PREVIEW; then PROTONX_APP_NAME='ProtonX Preview'; PROTONX_EXECUTABLE=ProtonXPreview; fi
if $PROTONX_PREVIEW && $PROTONX_INSTALL; then echo 'Preview builds cannot be installed as ProtonX.' >&2; exit 1; fi
if $PROTONX_PREVIEW && $PROTONX_STAGE_UPDATE; then echo 'Choose preview or staged update.' >&2; exit 1; fi
if $PROTONX_STAGE_UPDATE; then PROTONX_APP_NAME="$PROTONX_UPDATE_NAME"; fi
PROTONX_FINAL="$PROTONX_ROOT/build/$PROTONX_APP_NAME.app"
PROTONX_TARGET_RUNNING=false
# Check the exact bundle: another staged bundle may share its executable name.
if [[ -f "$PROTONX_FINAL/Contents/MacOS/$PROTONX_EXECUTABLE" ]] && lsof -t "$PROTONX_FINAL/Contents/MacOS/$PROTONX_EXECUTABLE" >/dev/null 2>&1; then PROTONX_TARGET_RUNNING=true; fi
if $PROTONX_TARGET_RUNNING; then
  echo 'Quit ProtonX before rebuilding its app bundle.' >&2
  exit 1
fi
if ! $PROTONX_SKIP_HELPER; then
  scripts/build-helper.sh
  scripts/build-mail-helper.sh
fi
[[ -f upstream/pass-cli/target/release/pass-cli ]] || { echo 'Build the helper first.' >&2; exit 1; }
[[ -f .tools/mail-helper/protonx-mail ]] || { echo 'Build the Mail helper first.' >&2; exit 1; }
"$PROTONX_SWIFT" build --build-system native -c release ${PROTONX_SWIFT_OPTIONS[@]+"${PROTONX_SWIFT_OPTIONS[@]}"}
PROTONX_BIN_DIR="$("$PROTONX_SWIFT" build --build-system native -c release --show-bin-path ${PROTONX_SWIFT_OPTIONS[@]+"${PROTONX_SWIFT_OPTIONS[@]}"})"
mkdir -p "$PROTONX_ROOT/build"
PROTONX_STAGE="$(mktemp -d "$PROTONX_ROOT/build/.app-stage.XXXXXX")"
trap 'rm -rf "$PROTONX_STAGE"' EXIT
PROTONX_BUNDLE="$PROTONX_STAGE/$PROTONX_APP_NAME.app"
mkdir -p "$PROTONX_BUNDLE/Contents/"{MacOS,Helpers,Resources}
cp "$PROTONX_BIN_DIR/ProtonX" "$PROTONX_BUNDLE/Contents/MacOS/$PROTONX_EXECUTABLE"
cp upstream/pass-cli/target/release/pass-cli "$PROTONX_BUNDLE/Contents/Helpers/protonx-pass"
cp .tools/mail-helper/protonx-mail "$PROTONX_BUNDLE/Contents/Helpers/protonx-mail"
cp Resources/Info.plist "$PROTONX_BUNDLE/Contents/Info.plist"
if $PROTONX_PREVIEW; then
  /usr/libexec/PlistBuddy -c 'Delete :CFBundleURLTypes' "$PROTONX_BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier org.kevb.ProtonX.Preview' "$PROTONX_BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable ProtonXPreview' "$PROTONX_BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName ProtonX Preview' "$PROTONX_BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName ProtonX Preview' "$PROTONX_BUNDLE/Contents/Info.plist"
fi
cp LICENSE LICENSE-MAIL-HELPER THIRD_PARTY_NOTICES.md upstream.lock.json Resources/MailProtocol.json Resources/DesktopProtocol.json "$PROTONX_BUNDLE/Contents/Resources/"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$PROTONX_BUNDLE/Contents/Resources/"; fi
# A configured local certificate preserves Keychain designated requirements across
# rebuilds. The portable default stays ad-hoc. No Keychain ACL is relaxed here.
PROTONX_SIGN_IDENTITY="${PROTONX_SIGN_IDENTITY:-}"
if [[ -z "$PROTONX_SIGN_IDENTITY" && -f .tools/signing-identity ]]; then
  IFS= read -r PROTONX_SIGN_IDENTITY < .tools/signing-identity
fi
PROTONX_SIGN_IDENTITY="${PROTONX_SIGN_IDENTITY:--}"
codesign --force --sign "$PROTONX_SIGN_IDENTITY" --timestamp=none --options runtime --identifier org.kevb.ProtonX.PassHelper "$PROTONX_BUNDLE/Contents/Helpers/protonx-pass"
codesign --force --sign "$PROTONX_SIGN_IDENTITY" --timestamp=none --options runtime --identifier org.kevb.ProtonX.MailHelper "$PROTONX_BUNDLE/Contents/Helpers/protonx-mail"
codesign --force --sign "$PROTONX_SIGN_IDENTITY" --timestamp=none --options runtime "$PROTONX_BUNDLE"
codesign --verify --deep --strict "$PROTONX_BUNDLE"
# Replace the generated bundle only after signing succeeds. Do not overwrite
# executables mapped by an already-running app.
PROTONX_FINAL="$PROTONX_ROOT/build/$PROTONX_APP_NAME.app"
if [[ -e "$PROTONX_FINAL" ]]; then mv "$PROTONX_FINAL" "$PROTONX_STAGE/Previous.app"; fi
if ! mv "$PROTONX_BUNDLE" "$PROTONX_FINAL"; then
  if [[ -e "$PROTONX_STAGE/Previous.app" ]]; then mv "$PROTONX_STAGE/Previous.app" "$PROTONX_FINAL"; fi
  exit 1
fi
echo "$PROTONX_FINAL"
if $PROTONX_INSTALL; then
  scripts/build-launchers.sh
  python3 scripts/install-app.py "$PROTONX_FINAL" --launchers "$PROTONX_ROOT/build/Launchers"
fi
