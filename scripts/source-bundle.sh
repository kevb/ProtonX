#!/usr/bin/env bash
# Complete helper source/dependency bundle to accompany any binary distribution.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROTONX_ROOT"
scripts/build-helper.sh
mkdir -p "$PROTONX_ROOT/build"
PROTONX_STAGE="$(mktemp -d "$PROTONX_ROOT/build/.source-stage.XXXXXX")"
trap 'rm -rf "$PROTONX_STAGE"' EXIT
PROTONX_SOURCE="$PROTONX_STAGE/ProtonX-0.1.0-source"
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
printf '\n' >> "$PROTONX_SOURCE/helper/.cargo/config.toml"
cat "$PROTONX_SOURCE/helper/vendor-config.toml" >> "$PROTONX_SOURCE/helper/.cargo/config.toml"
cp THIRD_PARTY_NOTICES.md LICENSE "$PROTONX_SOURCE/"
git rev-parse HEAD > "$PROTONX_SOURCE/SOURCE_REVISION.txt"
# An inventory points to the original license declarations; vendor directories
# contain the original source, copyright notices and license files.
python3 - "$PROTONX_SOURCE" <<'PYNOTICES'
import json, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1])
metadata = json.loads(subprocess.check_output(
    ['cargo', 'metadata', '--offline', '--locked', '--format-version', '1'], cwd=root/'helper'))
with (root/'DEPENDENCIES.tsv').open('w') as output:
    output.write('name\tversion\tlicense\tsource_directory\n')
    for package in sorted(metadata['packages'], key=lambda package: (package['name'], package['version'])):
        source = Path(package['manifest_path']).parent.relative_to(root)
        output.write('\t'.join([package['name'], package['version'], package.get('license') or 'See source license files', str(source)])+'\n')
PYNOTICES
cat > "$PROTONX_SOURCE/BUILDING.md" <<'BUILDING'
# Rebuild this source bundle

Use a Mac with Xcode 16+/Swift 6, Git, Python 3 and Rust stable (tested with 1.99).
Accept Xcode's license first. No Proton account is needed. The helper's crates
are included under `helper/vendor`, including their original license files.
`SOURCE_REVISION.txt` identifies the ProtonX commit; `DEPENDENCIES.tsv` indexes
all helper packages and their license declarations. `protonx/upstream.lock.json`
records the original upstream revision; the helper source already has the patch.

From this directory:

```sh
cd helper
cargo build --offline --locked --release -p pass-cli --features protonx-desktop
cargo test --offline --locked -p pass-cli --features protonx-desktop
cd ../protonx
mkdir -p upstream/pass-cli/target/release
cp ../helper/target/release/pass-cli upstream/pass-cli/target/release/pass-cli
./scripts/build-app.sh --skip-helper
swift test
./scripts/test-bridge.sh
./scripts/test-bridge.sh --starttls
```

The build produces `protonx/build/ProtonX.app` with local ad-hoc signatures.
It does not notarize or install the app. Keep this source archive available
alongside any binary distribution. See `LICENSE` and `THIRD_PARTY_NOTICES.md`.
BUILDING
tar -czf "$PROTONX_STAGE/ProtonX-0.1.0-source.tar.gz" -C "$PROTONX_STAGE" ProtonX-0.1.0-source
# Preserve the previous generated package until its replacement is complete.
if [[ -e build/ProtonX-0.1.0-source ]]; then mv build/ProtonX-0.1.0-source "$PROTONX_STAGE/Previous-source"; fi
mv "$PROTONX_SOURCE" build/ProtonX-0.1.0-source
mv "$PROTONX_STAGE/ProtonX-0.1.0-source.tar.gz" build/ProtonX-0.1.0-source.tar.gz
