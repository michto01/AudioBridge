#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-debug}"
case "$BUILD_CONFIGURATION" in debug|release) ;; *) echo "Invalid build configuration" >&2; exit 1;; esac
BINARY_DIR="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)"
BINARY="$BINARY_DIR/AudioBridge"
DIST="${DIST_DIR:-dist}"
case "$DIST" in /*) ;; *) DIST="$ROOT/$DIST";; esac
DEST="$DIST/AudioBridge.app"
[[ -x "$BINARY" ]] || { echo "Missing executable: $BINARY" >&2; exit 1; }
mkdir -p "$DIST"
if [[ -e "$DEST" || -L "$DEST" ]]; then
  [[ ! -L "$DEST" && -f "$DEST/Contents/Info.plist" ]] || { echo "Refusing to replace unrelated bundle" >&2; exit 1; }
  ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$DEST/Contents/Info.plist")"
  [[ "$ID" == cz.bytelab.audiobridge ]] || { echo "Refusing to replace unrelated bundle: $ID" >&2; exit 1; }
fi
STAGE="$(mktemp -d "$DIST/.package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/AudioBridge.app/Contents/MacOS" "$STAGE/AudioBridge.app/Contents/Resources"
cp "$BINARY" "$STAGE/AudioBridge.app/Contents/MacOS/AudioBridge"
chmod 755 "$STAGE/AudioBridge.app/Contents/MacOS/AudioBridge"
cp "$ROOT/Resources/Info.plist" "$STAGE/AudioBridge.app/Contents/Info.plist"
# SwiftPM resource bundles, if introduced later, belong beside the executable.
for RESOURCE in "$BINARY_DIR"/*.bundle; do
  [[ -d "$RESOURCE" ]] || continue
  cp -R "$RESOURCE" "$STAGE/AudioBridge.app/Contents/MacOS/"
done
plutil -lint "$STAGE/AudioBridge.app/Contents/Info.plist"
rm -rf "$DEST"
mv "$STAGE/AudioBridge.app" "$DEST"
# Finder/File Provider can attach signing-invalid metadata to generated bundles.
# Preserve all other attributes, including quarantine.
xattr -r -d com.apple.FinderInfo "$DEST" || true
xattr -r -d com.apple.ResourceFork "$DEST" || true
echo "Created $DEST"
