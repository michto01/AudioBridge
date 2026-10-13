#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# File Provider attaches FinderInfo to .xctest bundles in this checkout.
# Build tests in an isolated temporary directory so default SwiftPM signing works.
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/AudioBridge-tests.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
read -r -a SWIFT_BUILD_ARGS <<< "${SWIFT_BUILD_OPTIONS:-}"
# Preserve zero arguments for an empty option list under stock Bash 3.2 nounset.
swift test -c "${BUILD_CONFIGURATION:-debug}" ${SWIFT_BUILD_ARGS[@]+"${SWIFT_BUILD_ARGS[@]}"} --scratch-path "$SCRATCH"
