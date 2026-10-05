#!/usr/bin/env bash
# Opt-in only: designated test account. No passwords in arguments or environment.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROTONX_ROOT"
PROTONX_TEST_BUNDLE="$PROTONX_ROOT/.tools/ProtonXTestAccount.app"
PROTONX_TEST_EXECUTABLE="$PROTONX_TEST_BUNDLE/Contents/MacOS/ProtonXTestAccount"
case "${1:-}" in
  prepare)
    if pgrep -x ProtonXTestAccount >/dev/null; then
      echo 'Close the test-account form before rebuilding it.' >&2; exit 1
    fi
    if [[ -x "$PROTONX_TEST_EXECUTABLE" ]] && [[ "$("$PROTONX_TEST_EXECUTABLE" --probe)" != not-configured ]]; then
      echo 'Clear the temporary test credential before rebuilding the tool.' >&2; exit 1
    fi
    "$PROTONX_SWIFT" build -c release --product ProtonXValidation
    PROTONX_TEST_BIN="$("$PROTONX_SWIFT" build -c release --show-bin-path)/ProtonXValidation"
    mkdir -p "$PROTONX_TEST_BUNDLE/Contents/MacOS"
    cp "$PROTONX_TEST_BIN" "$PROTONX_TEST_EXECUTABLE"
    cat > "$PROTONX_TEST_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.kevb.ProtonX.Testing</string>
<key>CFBundleName</key><string>ProtonX Test Account</string>
<key>CFBundleExecutable</key><string>ProtonXTestAccount</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
    codesign --force --sign - "$PROTONX_TEST_BUNDLE"
    ;;
  setup) open "$PROTONX_TEST_BUNDLE" ;;
  check) "$PROTONX_TEST_EXECUTABLE" --probe ;;
  clear) "$PROTONX_TEST_EXECUTABLE" --clear ;;
  run|session)
    [[ -x "$PROTONX_TEST_EXECUTABLE" ]] || { echo 'Run scripts/test-account.sh prepare first.' >&2; exit 1; }
    PROTONX_TEST_MODE=--validate
    [[ "$1" != session ]] || PROTONX_TEST_MODE=--validate-session
    "$PROTONX_TEST_EXECUTABLE" "$PROTONX_TEST_MODE" "$PROTONX_ROOT/build/ProtonX.app/Contents/Helpers/protonx-pass" "$HOME/Library/Application Support/ProtonX/Pass"
    ;;
  *) echo 'Usage: scripts/test-account.sh prepare|setup|check|clear|run|session' >&2; exit 2 ;;
esac
