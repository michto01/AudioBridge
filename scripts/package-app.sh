#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-debug}"
case "$BUILD_CONFIGURATION" in debug|release) ;; *) echo "Invalid build configuration" >&2; exit 1;; esac
read -r -a SWIFT_BUILD_ARGS <<< "${SWIFT_BUILD_OPTIONS:-}"
BINARY_DIR="$(swift build -c "$BUILD_CONFIGURATION" "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
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
  RUNNING_EXECUTABLE="$(cd "$DEST" && pwd -P)/Contents/MacOS/AudioBridge"
  PROCESS_PATHS="$(/bin/ps -axo comm=)" || { echo "Cannot check running apps; quit AudioBridge or use a new DIST_DIR before packaging." >&2; exit 1; }
  while IFS= read -r PROCESS_PATH; do
    PROCESS_PATH="${PROCESS_PATH#"${PROCESS_PATH%%[![:space:]]*}"}"
    [[ "$PROCESS_PATH" != "$RUNNING_EXECUTABLE" ]] || {
      echo "Refusing to replace a running AudioBridge bundle. Quit it first or use a new DIST_DIR; replacing its helper can break the active app." >&2
      exit 1
    }
  done <<< "$PROCESS_PATHS"
fi
STAGE="$(mktemp -d "$DIST/.package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/AudioBridge.app/Contents/MacOS" "$STAGE/AudioBridge.app/Contents/Resources"
cp "$BINARY" "$STAGE/AudioBridge.app/Contents/MacOS/AudioBridge"
mkdir -p "$STAGE/AudioBridge.app/Contents/Helpers"
cp "$BINARY_DIR/AudioBridgeAUWorker" "$STAGE/AudioBridge.app/Contents/Helpers/AudioBridgeAUWorker"
chmod 755 "$STAGE/AudioBridge.app/Contents/Helpers/AudioBridgeAUWorker"
chmod 755 "$STAGE/AudioBridge.app/Contents/MacOS/AudioBridge"
cp "$ROOT/Resources/Info.plist" "$STAGE/AudioBridge.app/Contents/Info.plist"
# Build a complete macOS icon family from the user-supplied source artwork.
ICONSET="$STAGE/AudioBridge.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  /usr/bin/sips -z "$SIZE" "$SIZE" "$ROOT/Resources/AudioBridge.png" \
    --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE_SIZE=$((SIZE * 2))
  /usr/bin/sips -z "$DOUBLE_SIZE" "$DOUBLE_SIZE" "$ROOT/Resources/AudioBridge.png" \
    --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
ICON="$STAGE/AudioBridge.app/Contents/Resources/AudioBridge.icns"
if ! /usr/bin/iconutil -c icns "$ICONSET" -o "$ICON" >/dev/null 2>&1; then
  # Some recent macOS SDK/tool environments reject a valid generated iconset.
  # ICNS PNG chunks are a standard Apple format; pack the same sips images as a fallback.
  echo "iconutil rejected the generated iconset; using the standard ICNS PNG-chunk fallback."
  python3 - "$ICONSET" "$ICON" <<'PY'
import pathlib, struct, sys
source, destination = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
representations = [
    (b"icp4", "icon_16x16.png"),
    (b"icp5", "icon_16x16@2x.png"),
    (b"icp6", "icon_32x32@2x.png"),
    (b"ic07", "icon_128x128.png"),
    (b"ic08", "icon_128x128@2x.png"),
    (b"ic09", "icon_256x256@2x.png"),
    (b"ic10", "icon_512x512@2x.png"),
]
chunks = bytearray()
for kind, name in representations:
    payload = (source / name).read_bytes()
    chunks.extend(struct.pack(">4sI", kind, len(payload) + 8))
    chunks.extend(payload)
destination.write_bytes(struct.pack(">4sI", b"icns", len(chunks) + 8) + chunks)
PY
fi
[[ -s "$ICON" ]] || { echo "Unable to create AudioBridge.icns" >&2; exit 1; }
# SwiftPM Bundle.module resolves resource bundles from the app resourceURL.
RESOURCE="$BINARY_DIR/AudioBridge_AudioBridgeStrings.bundle"
[[ -d "$RESOURCE" ]] || { echo "Missing operator-language resources: $RESOURCE" >&2; exit 1; }
cp -R "$RESOURCE" "$STAGE/AudioBridge.app/Contents/Resources/"
plutil -lint "$STAGE/AudioBridge.app/Contents/Info.plist"
rm -rf "$DEST"
mv "$STAGE/AudioBridge.app" "$DEST"
# Finder/File Provider can attach signing-invalid metadata to generated bundles.
# Preserve all other attributes, including quarantine.
xattr -r -d com.apple.FinderInfo "$DEST" || true
xattr -r -d com.apple.ResourceFork "$DEST" || true
echo "Created $DEST"
