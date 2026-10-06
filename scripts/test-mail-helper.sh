#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROTONX_ROOT"
python3 scripts/prepare-mail-helper.py
python3 scripts/verify-mail-contract.py
export CARGO_TARGET_DIR="${PROTONX_MAIL_TARGET_DIR:-$PROTONX_ROOT/.tools/mail-native-target}"
cd .tools/mail-native
cargo test --locked -p protonx-mail-helper --profile mail-macos-debug
# Upstream uses local synthetic fixtures; no Proton credentials or production API.
cargo test --locked -p mail-common --test message_mail_scroller --profile mail-macos-debug

cargo test --locked -p mail-common --test message_body --profile mail-macos-debug

# Composer, sender selection (including BYOE), recipient validation and delivery
# use upstream local mock servers and public synthetic keys only.
cargo test --locked -p mail-common --test draft_change_sender --test draft_constructors --test draft_recipients --test draft_send --test protonx_linked_sender --profile mail-macos-debug
