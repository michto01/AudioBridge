#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BASE_REF="${1:-1c2acef}"
BENCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/AudioBridge-bench.XXXXXX")"
trap 'rm -rf "$BENCH_DIR"' EXIT
for file in AdaptiveDSP.c StereoRouting.c; do
    git show "${BASE_REF}:Sources/AudioBridgeRealtime/${file}" > "$BENCH_DIR/$file"
done
INCLUDE="$ROOT/Sources/AudioBridgeRealtime/include"
xcrun clang -O3 -I "$INCLUDE" "$BENCH_DIR/AdaptiveDSP.c" "$BENCH_DIR/StereoRouting.c" scripts/benchmarks/processing.c -o "$BENCH_DIR/baseline"
xcrun clang -O3 -DPREPARED -I "$INCLUDE" Sources/AudioBridgeRealtime/AdaptiveDSP.c Sources/AudioBridgeRealtime/StereoRouting.c scripts/benchmarks/processing.c -o "$BENCH_DIR/current"
for trial in 1 2 3 4 5; do
    echo "trial=$trial baseline=$BASE_REF"
    "$BENCH_DIR/baseline"
    echo "trial=$trial current"
    "$BENCH_DIR/current"
done
