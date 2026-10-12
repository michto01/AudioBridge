# Output device volume

Version 0.5.0, build 23. Implemented 2026-10-12. `make build` passed. `make DIST_DIR=/tmp/AudioBridge-device-volume sign` and `make DIST_DIR=/tmp/AudioBridge-device-volume verify` passed; bundle ID `cz.bytelab.audiobridge`, minimum macOS 14.0, version 0.5.0/build 23, embedded Info.plist match and ad-hoc signatures were verified. Hardware volume behavior is pending manual confirmation.

The Bridge output card now separates **Output gain** (Audio Bridge's digital processing gain) from **Device volume** (the selected output's Core Audio master output volume scalar). The device control reads/writes the explicitly selected output UID, is available without relying on the macOS menu bar, and runs on a utility queue with short slider-update coalescing. The value is read back because devices may quantize it to supported steps. Diagnostics/Copy status includes the scalar, writability and any property error.

The control is enabled only when Core Audio exposes the output-scope master `kAudioDevicePropertyVolumeScalar` and marks it writable. Some devices expose no master control or a read-only value; in that case the UI explains why the slider is disabled. Device volume may be shared with system audio clients and is distinct from software output gain. No output hardware volume control is assumed or created.

## Manual acceptance (deferred)

1. Open Settings → Bridge and adjust **Device volume** on the selected output while routing, including with exclusive access enabled.
2. Confirm the device volume changes and the displayed value follows the device's actual supported steps.
3. Confirm **Output gain** remains independently adjustable and changes signal level without changing the device volume scalar.
4. Try a device without a writable master volume control and confirm the UI shows a reason and does not offer an active slider.

Automated tests and live output checks were not run in this implementation turn.
