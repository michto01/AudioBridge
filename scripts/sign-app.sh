#!/bin/bash
set -euo pipefail
APP="${1:-dist/AudioBridge.app}"
ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[[ "$ID" == cz.bytelab.audiobridge ]] || { echo "Refusing to sign unrelated bundle" >&2; exit 1; }
# Sign outside File Provider storage, where Finder metadata cannot race codesign.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/AudioBridge-sign.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto --norsrc "$APP" "$STAGE/AudioBridge.app"
xattr -r -d com.apple.FinderInfo "$STAGE/AudioBridge.app" || true
xattr -r -d com.apple.ResourceFork "$STAGE/AudioBridge.app" || true
codesign --force --sign - "$STAGE/AudioBridge.app/Contents/Helpers/AudioBridgeAUWorker"
codesign --force --sign - "$STAGE/AudioBridge.app"
codesign --verify --deep --strict --verbose=2 "$STAGE/AudioBridge.app"
ditto --norsrc "$STAGE/AudioBridge.app" "$APP"
xattr -r -d com.apple.ResourceFork "$APP" || true
xattr -r -d com.apple.FinderInfo "$APP" || true
codesign --verify --deep --strict --verbose=2 "$APP"
