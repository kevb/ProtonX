#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROTONX_ROOT"
PROTONX_MAIL_FEATURES=()
PROTONX_MAIL_OUTPUT="$PROTONX_ROOT/.tools/mail-helper"
if [[ "${1:-}" == --secure-storage && $# == 1 ]]; then
  PROTONX_MAIL_FEATURES=(--features secure-storage)
  PROTONX_MAIL_OUTPUT="$PROTONX_ROOT/.tools/mail-helper-secure"
elif [[ $# != 0 ]]; then
  echo 'Use no arguments, or --secure-storage for the isolated experimental helper.' >&2
  exit 1
fi
python3 scripts/bootstrap.py --references
python3 scripts/prepare-mail-helper.py
python3 scripts/verify-mail-contract.py
export CARGO_TARGET_DIR="${PROTONX_MAIL_TARGET_DIR:-$PROTONX_ROOT/.tools/mail-native-target}"
cd .tools/mail-native
cargo build --locked -p protonx-mail-helper --profile mail-macos ${PROTONX_MAIL_FEATURES[@]+"${PROTONX_MAIL_FEATURES[@]}"}
mkdir -p "$PROTONX_MAIL_OUTPUT"
cp "$CARGO_TARGET_DIR/mail-macos/protonx-mail" "$PROTONX_MAIL_OUTPUT/protonx-mail"
# Remove local symbols from the packaged executable, retaining them in the target.
strip -x "$PROTONX_MAIL_OUTPUT/protonx-mail"
