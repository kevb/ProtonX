#!/usr/bin/env python3
"""Verify the native protocol identity against the immutable desktop source."""
import json, pathlib, re, subprocess
root = pathlib.Path(__file__).resolve().parent.parent
contract = json.loads((root/'Resources/DesktopProtocol.json').read_text())
locked = json.loads((root/'upstream.lock.json').read_text())
source = next(source for source in locked['sources'] if source['name'] == 'WebClients')
assert contract['revision'] == source['revision'], 'Desktop source pin mismatch'
def read(path):
    return subprocess.check_output(['git', 'show', source['revision']+':'+path], cwd=root/'upstream/WebClients', text=True)
package = json.loads(read('applications/pass-desktop/package.json'))
constants = read('packages/shared/lib/constants.ts')
section = constants.split('[APPS.PROTONPASS]: {',1)[1].split('},',1)[0]
client = re.search(r"macosClientID: '([^']+)'", section).group(1)
assert (contract['clientID'], contract['version']) == (client, package['version']), 'Desktop protocol changed'
assert f"clientType: {contract['clientType']}" in read('applications/pass-desktop/appConfig.ts')
account_fork = read('applications/account/src/app/content/fork/handleDesktopFork.ts')
assert 'deserializeQrCodePayload' in account_fork and 'childClientId.includes(strippedApp)' in account_fork
assert contract['deviceForkPath'] in (root/'upstream/pass-cli/pass/src/auth/web_login.rs').read_text()
header = client+'@'+package['version']
assert f'api_header: "{header}"' in (root/'upstream/pass-cli/pass-cli/src/protonx.rs').read_text()
print('Desktop API identity verified against pinned Proton source: '+header)
