#!/usr/bin/env bash
# Prefer the user's selected Xcode. A local command-line-tools fallback is useful before first launch.
set -euo pipefail
PROTONX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! xcrun --find swift >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
  export PATH="/Library/Developer/CommandLineTools/usr/bin:$PATH"
  PROTONX_SWIFT=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
else
  PROTONX_SWIFT="$(xcrun --find swift)"
  export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
fi
if [[ -x "$PROTONX_ROOT/.tools/cargo/bin/cargo" ]]; then
  export CARGO_HOME="$PROTONX_ROOT/.tools/cargo" RUSTUP_HOME="$PROTONX_ROOT/.tools/rustup"
  export PATH="$CARGO_HOME/bin:$PATH"
fi
export MACOSX_DEPLOYMENT_TARGET=14.0
