#!/usr/bin/env bash
# Complete helper source/dependency bundle to accompany any binary distribution.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROTONX_ROOT"
scripts/build-helper.sh
PROTONX_SOURCE="$PROTONX_ROOT/build/ProtonX-0.1.0-source"
mkdir -p "$PROTONX_SOURCE/helper" "$PROTONX_SOURCE/protonx"
(cd upstream/pass-cli && cargo vendor --locked "$PROTONX_SOURCE/helper/vendor" > "$PROTONX_SOURCE/helper/vendor-config.toml")
# Git-tracked source only: never package local profiles, test keys, build logs or toolchain state.
git archive HEAD | tar -x -C "$PROTONX_SOURCE/protonx"
git -C upstream/pass-cli archive HEAD | tar -x -C "$PROTONX_SOURCE/helper"
cp Resources/PassHelper.lock "$PROTONX_SOURCE/helper/Cargo.lock"
sed -i.bak 's|directory = ".*"|directory = "vendor"|' "$PROTONX_SOURCE/helper/vendor-config.toml"
rm "$PROTONX_SOURCE/helper/vendor-config.toml.bak"
(cd "$PROTONX_SOURCE/helper" && git apply "$PROTONX_ROOT/patches/pass-cli.patch")
mkdir -p "$PROTONX_SOURCE/helper/.cargo"
cat "$PROTONX_SOURCE/helper/vendor-config.toml" >> "$PROTONX_SOURCE/helper/.cargo/config.toml"
cp THIRD_PARTY_NOTICES.md LICENSE "$PROTONX_SOURCE/"
tar -czf "build/ProtonX-0.1.0-source.tar.gz" -C build ProtonX-0.1.0-source
