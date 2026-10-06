#!/usr/bin/env bash
# Only temporary synthetic files. No Keychain or installed profile is accessed.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROTONX_ROOT"
python3 scripts/prepare-mail-helper.py
python3 scripts/verify-mail-contract.py
python3 scripts/verify-mail-storage-features.py
export CARGO_TARGET_DIR="${PROTONX_MAIL_TARGET_DIR:-$PROTONX_ROOT/.tools/mail-native-target}"
cd .tools/mail-native
cargo test --locked -p protonx-mail-storage -p protonx-mail-helper --features protonx-mail-helper/secure-storage --profile mail-macos-debug

cargo build --locked -p protonx-mail-helper --features secure-storage --profile mail-macos-debug
python3 "$PROTONX_ROOT/Tools/MailContractTests/storage_preflight.py" "$CARGO_TARGET_DIR/mail-macos-debug/protonx-mail"
