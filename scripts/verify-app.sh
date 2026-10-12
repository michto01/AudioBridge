#!/bin/bash
set -euo pipefail
APP="${1:-dist/AudioBridge.app}"
PLIST="$APP/Contents/Info.plist"
plutil -lint "$PLIST"
check() {
  local VALUE
  VALUE="$(/usr/libexec/PlistBuddy -c "Print :$1" "$PLIST")"
  [[ "$VALUE" == "$2" ]] || { echo "Invalid $1: $VALUE" >&2; exit 1; }
  echo "$1=$VALUE"
}
check CFBundleIdentifier cz.bytelab.audiobridge
check CFBundleExecutable AudioBridge
check CFBundlePackageType APPL
check LSMinimumSystemVersion 14.0
check LSUIElement true
check CFBundleShortVersionString 0.5.5
check CFBundleVersion 28
check CFBundleIconFile AudioBridge.icns
[[ -s "$APP/Contents/Resources/AudioBridge.icns" ]]
DESCRIPTION="$(/usr/libexec/PlistBuddy -c "Print :NSMicrophoneUsageDescription" "$PLIST")"
[[ -n "$DESCRIPTION" ]]
LOCAL_NETWORK_DESCRIPTION="$(/usr/libexec/PlistBuddy -c "Print :NSLocalNetworkUsageDescription" "$PLIST")"
[[ -n "$LOCAL_NETWORK_DESCRIPTION" ]]
[[ -x "$APP/Contents/MacOS/AudioBridge" ]]
[[ -x "$APP/Contents/Helpers/AudioBridgeAUWorker" ]]
# Verify the executable carries exactly the same identity/icon metadata as its bundle.
read -r PLIST_OFFSET PLIST_SIZE < <(/usr/bin/otool -l "$APP/Contents/MacOS/AudioBridge" | awk '
  $1 == "sectname" { selected = ($2 == "__info_plist") }
  selected && $1 == "offset" { offset = $2 }
  selected && $1 == "size" { size = $2 }
  END { print offset, size }')
[[ "$PLIST_OFFSET" =~ ^[0-9]+$ && "$PLIST_SIZE" =~ ^0x[0-9a-fA-F]+$ ]]
EMBEDDED_PLIST="$(mktemp "${TMPDIR:-/tmp}/AudioBridge-plist.XXXXXX")"
trap 'rm -f "$EMBEDDED_PLIST"' EXIT
/bin/dd if="$APP/Contents/MacOS/AudioBridge" of="$EMBEDDED_PLIST" bs=1 skip="$PLIST_OFFSET" count="$((PLIST_SIZE))" 2>/dev/null
cmp -s "$PLIST" "$EMBEDDED_PLIST" || { echo "Executable and bundle metadata differ" >&2; exit 1; }
echo "Embedded executable metadata matches bundle"
codesign --verify --strict --verbose=2 "$APP/Contents/Helpers/AudioBridgeAUWorker"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --verbose=2 "$APP"
