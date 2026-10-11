#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# File Provider attaches FinderInfo to .xctest bundles in this checkout.
# Build tests in an isolated temporary directory so default SwiftPM signing works.
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/AudioBridge-tests.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
swift test -c "${BUILD_CONFIGURATION:-debug}" --scratch-path "$SCRATCH"
