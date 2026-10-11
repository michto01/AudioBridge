#!/bin/bash
set -euo pipefail
APP="${1:-dist/AudioBridge.app}"
[[ -d "$APP" ]] || { echo "Missing app bundle: $APP" >&2; exit 1; }
# Refresh this bundle's icon/version registration before opening. This does not
# reset microphone authorization or remove registrations for other applications.
REGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$REGISTER" -f "$APP"
open "$APP"
