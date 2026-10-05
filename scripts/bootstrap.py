#!/usr/bin/env python3
"""Download exact upstream source revisions. Never installs packages or changes an existing checkout."""
import argparse
import json
import pathlib
import subprocess
root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--references', action='store_true', help='Also download Mail, desktop, and native reference sources')
args = parser.parse_args()
for source in json.loads((root / 'upstream.lock.json').read_text())['sources']:
    if source['name'] != 'pass-cli' and not args.references:
        continue
    path = root / 'upstream' / source['name']
    if path.exists():
        current = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=path, text=True).strip()
        if current != source['revision']:
            raise SystemExit(f'{path}: unexpected revision; preserve or move the checkout before retrying')
        continue
    path.mkdir(parents=True)
    subprocess.run(['git', 'init', '-q', str(path)], check=True)
    subprocess.run(['git', 'remote', 'add', 'origin', source['url']], cwd=path, check=True)
    if source['name'] == 'WebClients':
        subprocess.run(['git', 'config', 'core.sparseCheckout', 'true'], cwd=path, check=True)
        (path / '.git/info/sparse-checkout').write_text('/applications/inbox-desktop/\n/applications/pass-desktop/\n/packages/shared/lib/auth/\n/packages/shared/lib/api/\n/LICENSE\n/package.json\n')
    subprocess.run(['git', 'fetch', '--depth=1', 'origin', source['revision']], cwd=path, check=True)
    subprocess.run(['git', 'checkout', '--detach', 'FETCH_HEAD'], cwd=path, check=True)
