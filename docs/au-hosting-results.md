# Installed AU effects follow-up — 2026-10-11

User requested trim above meters in the main Audio settings and menu popover, plus installed third-party AU effects. This explicitly extends the original no-extra-DSP scope. Build 0.2.3 (4) implements this slice; remaining phase gates are unchanged.

## Implementation

- `AudioBridgeAU`: effect registry metadata, exact component identity, versioned ordered chain with enabled flags and saved binary property-list state. Maximum eight slots; no automatic replacement of missing units.
- `AudioBridgeAUWorker`: SwiftPM executable bundled in `Contents/Helpers`, signed before the app. Separate process for editing and separate instance for rendering. Native editor where supplied, generic writable parameters and factory presets otherwise. Save applies on the next Start; cancel preserves previous state.
- `AUTransport`: preallocated shared-memory stereo SPSC queues with lock-free atomics. Capture writes trimmed samples; worker renders fixed 256-frame planar Float32 blocks; output reads processed samples and applies smooth gain. HAL callbacks never instantiate plugins, wait for IPC, or call Swift/UI. No audio samples are written to files.
- Optional extra buses disabled; units requiring them are rejected. No MIDI, sidechain routing, instruments, multichannel plugin routing or VST hosting. Reported AU latency is separate from unmeasured total latency.
- Preparation capped at 30 seconds and cancellable by Stop. Render errors, exited helper or heartbeat stalled for two seconds stop routing without bypass. Helper watches parent lifetime. Cleanup detaches HAL callbacks before freeing the mapping; failed detachment retains callback storage until process exit.
- Shared memory is private to the user, with a random name unlinked after readiness. Abrupt parent termination during preparation may leave a named mapping; orderly cancellation cleans it. This needs further hardening before unattended deployment.
- Process separation limits app crashes; it is not a security sandbox. Plugins retain user privileges and their own licensing/network behavior. No third-party package dependency added: hosting uses Apple's SDK.

## Actual commands

- `make build`: passed after correcting SDK API usage (bus arrays are indexed rather than Swift sequences). Final packaging rebuilt the parent-lifetime watchdog successfully.
- `make DIST_DIR=/tmp/AudioBridge-phase2 sign`: passed, including app packaging, icon generation and helper/app ad-hoc signing.
- `make DIST_DIR=/tmp/AudioBridge-phase2 verify`: passed. Info.plist confirmed `cz.bytelab.audiobridge`, executable `AudioBridge`, macOS minimum 14.0, menu-bar flag, icon, version 0.2.3/build 4. Strict helper and deep app signature verification passed (ad-hoc, arm64).
- Automated tests, plugin instantiation, live routing, `make run`, and long-duration tests: **not run**, following the user's deferral. Test source is written but not compiled or executed. Earlier phase toolchain evidence remains in the phase result documents; no new toolchain installation was performed.

## Deferred checks and prerequisites

`AUChainTests.swift` covers serialization, explicit bypass, schema/duplicate-ID validation and two mappings of the shared queue in one process. This does not test cross-process timing, actual plugin behavior or hardware.

Manual acceptance: load the installed compressor/limiter, edit and save, restart app, confirm state and chain order, observe measured processed frames and input/output meters, verify Stop during preparation, plugin crash/hang handling, missing plugin refusal, clipping behavior, AUv2/AUv3 editor compatibility and latency under load. Use an attended low-volume route before any deployment.

Still missing for unattended use: actual drift compensation, configurable matrix, desired-versus-observed supervisor, bounded automatic recovery, persisted manual Stop/login semantics, wider PCM/device support and prolonged fault/soak testing. No claim that this slice completes those phases or validates third-party plugin compatibility.
