#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROTONX_ROOT"
python3 scripts/bootstrap.py
if git -C upstream/pass-cli apply --reverse --check "$PROTONX_ROOT/patches/pass-cli.patch" 2>/dev/null; then
  : # The exact patch is already applied.
else
  python3 scripts/patch-helper.py
fi
cp Resources/PassHelper.lock upstream/pass-cli/Cargo.lock
command -v cargo >/dev/null || { echo 'Install the stable Rust toolchain from https://rustup.rs, then run this again.' >&2; exit 1; }
cd upstream/pass-cli
cargo build --locked --release -p pass-cli
