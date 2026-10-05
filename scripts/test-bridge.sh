#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROTONX_ROOT"
PROTONX_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/protonx-bridge.XXXXXX")"
PROTONX_FIXTURE_PID=''
cleanup() { if [[ -n "$PROTONX_FIXTURE_PID" ]]; then kill "$PROTONX_FIXTURE_PID" 2>/dev/null || true; wait "$PROTONX_FIXTURE_PID" 2>/dev/null || true; fi; rm -rf "$PROTONX_FIXTURE"; }
trap cleanup EXIT
cat > "$PROTONX_FIXTURE/openssl.cnf" <<'CONF'
[req]
distinguished_name=subject
x509_extensions=certificate
prompt=no
[subject]
CN=127.0.0.1
[certificate]
subjectAltName=IP:127.0.0.1
basicConstraints=critical,CA:TRUE
keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign
CONF
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config "$PROTONX_FIXTURE/openssl.cnf" -keyout "$PROTONX_FIXTURE/private-key.pem" -out "$PROTONX_FIXTURE/certificate.pem" >/dev/null 2>&1
# A different self-signed certificate must not authenticate the fixture's TLS endpoint.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config "$PROTONX_FIXTURE/openssl.cnf" -keyout "$PROTONX_FIXTURE/untrusted-key.pem" -out "$PROTONX_FIXTURE/untrusted.pem" >/dev/null 2>&1
python3 tests/bridge_fixture.py --directory "$PROTONX_FIXTURE" "${@}" &
PROTONX_FIXTURE_PID=$!
for ((i=0; i<100; i++)); do [[ -f "$PROTONX_FIXTURE/config.json" ]] && break; sleep 0.05; done
[[ -f "$PROTONX_FIXTURE/config.json" ]] || { echo 'Fixture did not start.' >&2; exit 1; }
PROTONX_UNTRUSTED_CERT="$PROTONX_FIXTURE/untrusted.pem" PROTONX_BRIDGE_TEST_CONFIG="$PROTONX_FIXTURE/config.json" "$PROTONX_SWIFT" test --build-system native --disable-xctest --filter syntheticBridgeRoundTrip
python3 - "$PROTONX_FIXTURE/sent.eml" <<'PY'
from email import policy
from email.parser import BytesParser
from pathlib import Path
import sys
message=BytesParser(policy=policy.default).parsebytes(Path(sys.argv[1]).read_bytes())
assert message['To']=='synthetic@example.com'
assert str(message['Subject'])=='Synthetic round trip'
assert message.get_content().strip()=='Synthetic SMTP payload'
print('Synthetic SMTP payload verified.')
PY
