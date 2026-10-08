#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROTONX_ROOT"
python3 scripts/bootstrap.py --references
python3 scripts/prepare-calendar-helper.py
python3 scripts/verify-calendar-contract.py
mkdir -p .tools/calendar-helper
export MACOSX_DEPLOYMENT_TARGET=14.0
export CGO_CFLAGS="-mmacosx-version-min=14.0" CGO_LDFLAGS="-mmacosx-version-min=14.0"
(cd .tools/calendar-native && CGO_ENABLED=1 go build -mod=readonly -trimpath -ldflags='-s -w' -o ../calendar-helper/protonx-calendar ./cmd/protonx-calendar)
