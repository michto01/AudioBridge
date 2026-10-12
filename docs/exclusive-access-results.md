# Exclusive device access

Version 0.5.0, build 22. Implemented 2026-10-12. `make doctor` found Xcode at `/Applications/Xcode.app`, Swift 6.4, arm64, and the macOS 27.0 SDK. `make build` passed after rerunning outside the restricted build sandbox; `make DIST_DIR=/tmp/AudioBridge-exclusive sign` and `make DIST_DIR=/tmp/AudioBridge-exclusive verify` passed. The verified bundle ID is `cz.bytelab.audiobridge`, deployment minimum 14.0, version 0.5.0/build 22, with matching embedded and bundle Info.plists. Automated tests and device/driver acceptance were not run.

Settings → Audio → Device access provides **Request exclusive device access while routing**, off by default to preserve shared-device behavior unless the operator opts in. At Start, the realtime engine's owning lifecycle queue requests Core Audio `kAudioDevicePropertyHogMode` for the explicitly selected input and output IDs before creating IOProcs. It reads the owner back and only proceeds when this process owns both devices. If input is acquired but output fails, input ownership is rolled back. No default-device substitution occurs.

The app releases ownership after IOProcs have detached and callbacks have left. If teardown or release cannot be confirmed, the engine context is retained and Start is blocked pending app restart. Copy status reports the preference and actual held state for each endpoint while a snapshot is available.

This is a request to the selected device's Core Audio driver, not an operating-system guarantee. A busy, non-settable, or unsupported device blocks Start with the affected endpoint named. While held, other apps may lose access to that device. Availability and behavior vary by device/driver. No automatic system-wide hog-mode policy is changed.

## Manual acceptance (deferred)

1. Enable the setting, Start, and confirm Copy status reports input and output held.
2. Attempt to use each selected device from a second audio app; record whether the driver denies or interrupts the second app.
3. Stop Audio Bridge and confirm the other app can open the devices again.
4. Repeat with a device already in use; confirm Start identifies the endpoint and does not retain a partial claim.
5. Repeat with a device that does not support settable hog mode; confirm shared mode works when the setting is off.

Automated tests and live hardware checks were not run in this implementation turn.
