#!/usr/bin/env bash
# Native launch-only apps. No independent helper, session, Dock or menu-bar owner.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROTONX_ROOT"
mkdir -p "$PROTONX_ROOT/build"
PROTONX_LAUNCH_STAGE="$(mktemp -d "$PROTONX_ROOT/build/.launchers-stage.XXXXXX")"
trap 'rm -rf "$PROTONX_LAUNCH_STAGE"' EXIT
"${PROTONX_SWIFT%/swift}/swiftc" -parse-as-library -O -target "$(uname -m)-apple-macos14.0" -sdk "$SDKROOT" Tools/ProductLauncher/main.swift -o "$PROTONX_LAUNCH_STAGE/ProductLauncher"
PROTONX_LAUNCH_IDENTITY="${PROTONX_SIGN_IDENTITY:-}"
if [[ -z "$PROTONX_LAUNCH_IDENTITY" && -f .tools/signing-identity ]]; then IFS= read -r PROTONX_LAUNCH_IDENTITY < .tools/signing-identity; fi
PROTONX_LAUNCH_IDENTITY="${PROTONX_LAUNCH_IDENTITY:--}"
for PROTONX_PRODUCT in Mail Pass; do
  PROTONX_LAUNCH_APP="$PROTONX_LAUNCH_STAGE/ProtonX $PROTONX_PRODUCT.app"
  mkdir -p "$PROTONX_LAUNCH_APP/Contents/"{MacOS,Resources}
  cp "$PROTONX_LAUNCH_STAGE/ProductLauncher" "$PROTONX_LAUNCH_APP/Contents/MacOS/ProductLauncher"
  python3 - "$PROTONX_LAUNCH_APP" "$PROTONX_PRODUCT" <<'PY'
import pathlib, plistlib, sys
bundle, product = pathlib.Path(sys.argv[1]), sys.argv[2]
info = dict(CFBundleName='ProtonX '+product, CFBundleDisplayName='ProtonX '+product,
            CFBundleIdentifier='org.kevb.ProtonX.'+product+'Launcher', CFBundleExecutable='ProductLauncher',
            CFBundlePackageType='APPL', CFBundleShortVersionString='0.1.0', CFBundleVersion='1',
            LSMinimumSystemVersion='14.0', LSUIElement=True, ProtonXProduct=product.lower(), CFBundleIconFile='AppIcon')
(bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
  cp Resources/AppIcon.icns "$PROTONX_LAUNCH_APP/Contents/Resources/"
  codesign --force --sign "$PROTONX_LAUNCH_IDENTITY" --timestamp=none --options runtime "$PROTONX_LAUNCH_APP"
  codesign --verify --strict "$PROTONX_LAUNCH_APP"
done
mkdir -p .tools/product-launchers
for PROTONX_PRODUCT in Mail Pass; do
  PROTONX_LAUNCH_FINAL="$PROTONX_ROOT/.tools/product-launchers/ProtonX $PROTONX_PRODUCT.app"
  if [[ -e "$PROTONX_LAUNCH_FINAL" ]]; then
    if lsof -t "$PROTONX_LAUNCH_FINAL/Contents/MacOS/ProductLauncher" >/dev/null 2>&1; then echo 'Close the launcher before rebuilding.' >&2; exit 1; fi
    mv "$PROTONX_LAUNCH_FINAL" "$PROTONX_LAUNCH_STAGE/Previous $PROTONX_PRODUCT.app"
  fi
  mv "$PROTONX_LAUNCH_STAGE/ProtonX $PROTONX_PRODUCT.app" "$PROTONX_LAUNCH_FINAL"
done
echo "$PROTONX_ROOT/.tools/product-launchers"
