#!/usr/bin/env bash
# Complete helper source/dependency bundle to accompany any binary distribution.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROTONX_ROOT"
scripts/build-helper.sh
mkdir -p "$PROTONX_ROOT/build"
# Outside the checkout: git apply otherwise discovers the enclosing ProtonX
# repository and can silently skip paths outside its current directory prefix.
PROTONX_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ProtonX-source.XXXXXX")"
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
# Corresponding source must match every tracked file of the built helper,
# including new patched modules, rather than merely compiling an upstream CLI.
python3 - "$PROTONX_ROOT" "$PROTONX_SOURCE/helper" <<'PYCHECK'
import subprocess, sys
from pathlib import Path
project, bundle = map(Path, sys.argv[1:])
checkout = project/'upstream/pass-cli'
paths = subprocess.check_output(['git', 'ls-files', '-z'], cwd=checkout).decode().split('\0')
for path in filter(None, paths):
    expected = project/'Resources/PassHelper.lock' if path == 'Cargo.lock' else checkout/path
    actual = bundle/path
    if not actual.is_file() or actual.read_bytes() != expected.read_bytes():
        raise SystemExit('Corresponding-source mismatch: '+path)
print('Corresponding helper source matches every tracked build input')
PYCHECK
mkdir -p "$PROTONX_SOURCE/helper/.cargo"
printf '\n' >> "$PROTONX_SOURCE/helper/.cargo/config.toml"
cat "$PROTONX_SOURCE/helper/vendor-config.toml" >> "$PROTONX_SOURCE/helper/.cargo/config.toml"
cp THIRD_PARTY_NOTICES.md LICENSE "$PROTONX_SOURCE/"
git rev-parse HEAD > "$PROTONX_SOURCE/SOURCE_REVISION.txt"
# An inventory points to the original license declarations; vendor directories
# contain the original source, copyright notices and license files.
python3 - "$PROTONX_SOURCE" "$PROTONX_ROOT/upstream/pass-cli" <<'PYNOTICES'
import json, shutil, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1])
original = json.loads(subprocess.check_output(
    ['cargo', 'metadata', '--offline', '--locked', '--format-version', '1'], cwd=sys.argv[2]))
# Cargo's git vendoring can omit a workspace-root license. Preserve it separately
# from the unmodified/checksummed vendor crate directories.
for package in original['packages']:
    if not (package.get('source') or '').startswith('git+'):
        continue
    directory = Path(package['manifest_path']).parent
    for parent in [directory, *directory.parents]:
        if '.cargo' in str(parent) and parent.name in ('git', 'checkouts'):
            break
        for name in ('LICENSE', 'COPYING', 'LICENSE.md', 'LICENSE.txt'):
            license_file = parent/name
            if license_file.is_file():
                destination = root/'helper/workspace-licenses'/f"{package['name']}-{package['version']}"
                destination.mkdir(parents=True, exist_ok=True)
                shutil.copy2(license_file, destination/name)
        if (parent/'.git').exists():
            break
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
