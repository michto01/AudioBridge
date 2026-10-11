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
check CFBundleShortVersionString 0.1.0
check CFBundleVersion 1
check CFBundleIconFile AudioBridge.icns
[[ -s "$APP/Contents/Resources/AudioBridge.icns" ]]
DESCRIPTION="$(/usr/libexec/PlistBuddy -c "Print :NSMicrophoneUsageDescription" "$PLIST")"
[[ -n "$DESCRIPTION" ]]
[[ -x "$APP/Contents/MacOS/AudioBridge" ]]
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --verbose=2 "$APP"
