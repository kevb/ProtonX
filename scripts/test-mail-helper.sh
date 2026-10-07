#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROTONX_ROOT"
python3 scripts/prepare-mail-helper.py
python3 scripts/verify-mail-contract.py
python3 scripts/verify-mail-storage-features.py
export CARGO_TARGET_DIR="${PROTONX_MAIL_TARGET_DIR:-$PROTONX_ROOT/.tools/mail-native-target}"
cd .tools/mail-native
cargo test --locked -p protonx-mail-helper --profile mail-macos-debug
cargo build --locked -p protonx-mail-helper --profile mail-macos-debug
python3 "$PROTONX_ROOT/Tools/MailContractTests/storage_preflight.py" "$CARGO_TARGET_DIR/mail-macos-debug/protonx-mail" --legacy
# Upstream uses local synthetic fixtures; no Proton credentials or production API.
cargo test --locked -p mail-common --test message_mail_scroller --profile mail-macos-debug

cargo test --locked -p mail-common --test message_body --profile mail-macos-debug

# A temporary SQLite fixture establishes the actual at-rest storage boundary.
cargo test --locked -p mail-common --test protonx_local_storage --profile mail-macos-debug

# Composer, sender selection (including BYOE), recipient validation and delivery
# use upstream local mock servers and public synthetic keys only.
cargo test --locked -p mail-common --test draft_change_sender --test draft_constructors --test draft_recipients --test draft_send --test protonx_linked_sender --profile mail-macos-debug

# Everyday inbox actions: genuine upstream queues, mock API, local/remote undo.
cargo test --locked -p mail-common --test actions_read_unread --test message_read_unread --test message_move --test protonx_conversation_actions --test attachment --profile mail-macos-debug

# Conversation identity, cross-folder members, Trash visibility and paging use
# the pinned SDK's genuine local/mock fixtures, without production credentials.
cargo test --locked -p mail-common --test mailbox_conversation --test conversation_mail_scroller --profile mail-macos-debug
