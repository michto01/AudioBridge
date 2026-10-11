# Optional debug display — 0.3.9 / build 18

Diagnostics now has a native “Show debug information in the interface” toggle. It defaults to false for each app launch and affects all views through the shared main-actor AppModel. It does not persist an enabled inspection mode across restarts.

Off hides Playback's queue counts/range, processing timings, drift/refill counters, detailed device/combined delay readouts and delay breakdown. Playback retains its compact estimated bridge/callback delay, status, meters, gains and controls. Audio hides live queue/drift counters, duplicate reserve values, reserve-range/timing explanations and supported hardware-range summaries. Editable buffer selections, exact/custom controls, actual hardware buffer readback, actionable faults and low-buffer configuration warnings remain available. Diagnostics and Copy status/export retain full information regardless of the switch. Audio processing and metering collection are unchanged.

Manual checks deferred: first launch off; enable/disable in Diagnostics and inspect Playback/Audio while running/stopped; confirm counter collection and Copy status are unaffected; relaunch resets off. No app, plugin, audio or automated test execution was performed under the standing user instruction. This UI slice does not pass Phase 3 hardware gates or advance Phase 4.

## Actual checks

- `make build`: passed, debug build complete in 3.99 s.
- `make BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-phase2 sign`: passed; production build complete in 14.00 s, plist lint/package and helper/app ad-hoc signing successful.
- `make BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-phase2 verify`: passed; version 0.3.9/build 18, cz.bytelab.audiobridge, macOS 14.0 minimum, AudioBridge executable/icon, embedded metadata matches bundle, arm64 helper/app signatures valid.
- `git diff --check`: passed. Tests and UI/runtime checks were not run.
