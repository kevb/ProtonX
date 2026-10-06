#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROTONX_ROOT"
PROTONX_PROBE_DIR="$(mktemp -d)"
trap 'rm -rf "$PROTONX_PROBE_DIR"' EXIT
# Only typecheck the API surface; never install or register a credential extension.
"${PROTONX_SWIFT}c" -swift-version 6 -warnings-as-errors -typecheck Experiments/CredentialProvider/OriginCandidate.swift Experiments/CredentialProvider/SDKProbe.swift
"${PROTONX_SWIFT}c" -swift-version 6 Experiments/CredentialProvider/OriginCandidate.swift Experiments/CredentialProvider/OriginTests.swift -o "$PROTONX_PROBE_DIR/origin-tests"
"$PROTONX_PROBE_DIR/origin-tests"
