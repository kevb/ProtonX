#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROTONX_ROOT"
python3 scripts/bootstrap.py --references
python3 scripts/prepare-mail-helper.py
python3 scripts/verify-mail-contract.py
export CARGO_TARGET_DIR="${PROTONX_MAIL_TARGET_DIR:-$PROTONX_ROOT/.tools/mail-native-target}"
cd .tools/mail-native
cargo build --locked -p protonx-mail-helper --profile mail-macos
mkdir -p "$PROTONX_ROOT/.tools/mail-helper"
cp "$CARGO_TARGET_DIR/mail-macos/protonx-mail" "$PROTONX_ROOT/.tools/mail-helper/protonx-mail"
# Remove local symbols from the packaged executable, retaining them in the target.
strip -x "$PROTONX_ROOT/.tools/mail-helper/protonx-mail"
