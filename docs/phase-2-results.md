# Phase 2 — Experimental manual audio path

## Scope and implementation

Implemented on 2026-10-11 after the user confirmed settings persistence and microphone permission and authorized continuing. The user subsequently deferred automated test execution and live audio checks. That instruction overrides the default per-slice test workflow; it does not count as passing an acceptance gate.

- `AudioBridgeRealtime`: preallocated stereo Float32 SPSC ring, independent C HAL input/output callbacks, atomic counters, and explicit start/stop/destroy ownership.
- `AudioBridgeEngine`: one serial lifecycle queue, fresh UID resolution at Start, strict stream validation, initial FIFO prefill, callback monitoring and device/format rechecks outside callbacks.
- App model/UI: explicit Start/Stop, route state separate from observed counters, controls locked during routing, persisted manual Stop, cleanup on Quit, actionable failures and raw counters in Diagnostics. No launch-time capture or retries.
- Settings use human-readable names and bounded system device icons. Device UIDs stay in Diagnostics and saved configuration.
- User-supplied `Resources/AudioBridge.png` is converted during packaging to all standard 16–512 point icon sizes and their 2× representations. `CFBundleIconFile` references the packaged `AudioBridge.icns`; bundle verification requires it to exist. The source artwork is preserved.
- Written FIFO tests cover invalid capacities, wrap, overflow, zero-fill starvation and a deterministic 1 kHz signal in each separate lane. They do not exercise HAL callbacks or prove physical channel routing.

Callback code has no Swift/ARC, allocation, logging, HAL property queries, UI calls or blocking waits. Scratch and ring storage are allocated before registration. Unselected output channels retain HAL's zero-filled buffers; starvation fills selected channels with zeros. Lifecycle cleanup disables processing, stops and unregisters callbacks, and checks in-flight callbacks before freeing. Failed detach retains context memory and reports a restart requirement. This is implementation review, not a completed runtime race or real-time safety audit.

## Current restrictions

The initial slice accepts two separate devices at equal current rates, one stream per selected direction, and packed native-endian Float32 PCM. Interleaved and planar IO are copied into/out of internal stereo Float32 according to explicitly selected physical channels. No defaults or device rates are changed. Other PCM representations, multiple streams and same-device duplex routing are rejected explicitly and remain work for universal compatibility; no vendor name is special-cased.

Identity matrix and fixed 0 dB gain only. Duplicate input selections copy into both logical lanes. Duplicate output selections sum both lanes into the chosen channel and can clip. No drift compensation, rate conversion, meters, configurable matrix/gain, automatic recovery, login startup or unattended operation. A fixed FIFO cannot solve independent clock drift. Initial prefill is a buffer count, not a measured latency promise.

## Actual commands and evidence

- `make build`: passed after UI/engine integration, SwiftPM reported `Build complete! (2,64 sec)`.
- `make DIST_DIR=/tmp/AudioBridge-phase2 sign`: passed; rebuilt, assembled `.app`, validated plist, ad-hoc signed and checked signature.
- `make DIST_DIR=/tmp/AudioBridge-phase2 verify`: passed; bundle identifier `cz.bytelab.audiobridge`, executable `AudioBridge`, minimum macOS `14.0`, `LSUIElement=true`, version `0.1.0` build `1`, strict ad-hoc signature valid (arm64).
- Repeated `make DIST_DIR=/tmp/AudioBridge-phase2 sign` and `verify` after adding the app icon: passed, `CFBundleIconFile=AudioBridge.icns`, one sealed resource. Finder appearance has not been manually checked.
- `make test`: **not run** at user request. New test source has not been compiled or executed.
- `make run`, HAL Start and live signal testing: **not run**. No physical or virtual route is claimed working.
- No new doctor/toolchain probe, release build, drift simulation or runtime race audit in this slice.

## Deferred manual checks

When ready, quit the older copy and open `/tmp/AudioBridge-phase2/AudioBridge.app` (or rebuild with `make DIST_DIR=/tmp/AudioBridge-phase2 run`). Temporary output is disposable. Select an input and output with equal nominal rates, grant permission if required, and explicitly select both physical lanes. Use an attended setup at a low monitoring level.

1. Start, confirm input/output callback and frame counters progress and FIFO primes. Status alone is not proof of correct audible routing.
2. Supply a known 1 kHz signal only on physical input lane 1: confirm only selected output lane 1 carries it. Repeat with only input lane 2 and selected output lane 2. Check unselected outputs remain silent.
3. Stop: confirm routing ceases; close/reopen Settings and quit/relaunch. Settings should persist; capture must not restart automatically in this phase.
4. Later test endpoint loss/return, format/rate changes, permission loss, repeated Start/Stop and sleep/wake. Confirm no default device substitution, no stale audio and clear errors. Reconnect requires manual Start in this phase.
5. Record actual device UIDs/formats, route, duration and glitch counts. Long runs with independently clocked devices are expected to need Phase 3 drift control; no reliability or latency conclusion follows from a short audible check.

Automated checks can be run later with `make test`; the Phase 2 physical signal and callback-lifetime gate remains pending. Review this slice before implementing Phase 3 adaptive resampling, matrix, gain and meters.
