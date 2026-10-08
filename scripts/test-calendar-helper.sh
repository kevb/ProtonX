#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROTONX_ROOT"
python3 scripts/prepare-calendar-helper.py
python3 scripts/verify-calendar-contract.py
export MACOSX_DEPLOYMENT_TARGET=14.0
export CGO_CFLAGS="-mmacosx-version-min=14.0" CGO_LDFLAGS="-mmacosx-version-min=14.0"
# In-memory session stores, official SRP mock server and synthetic OpenPGP only.
# Tests never install a Keychain backend or contact a Proton account.
(cd .tools/calendar-native && CGO_ENABLED=1 go test -mod=readonly ./cmd/protonx-calendar ./pkg/pgp ./pkg/event ./pkg/calendar ./pkg/recurrence ./pkg/ical ./pkg/icaltime ./pkg/papi)

if [[ -f .tools/calendar-helper/protonx-calendar ]]; then
  python3 Tools/CalendarContractTests/protocol_smoke.py .tools/calendar-helper/protonx-calendar
fi
