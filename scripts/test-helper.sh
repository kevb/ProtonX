#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROTONX_ROOT/upstream/pass-cli"
cargo test --locked -p pass-cli
cargo test --locked -p pass-cli --features protonx-desktop
cargo test --locked -p pass --features tokio-runtime
