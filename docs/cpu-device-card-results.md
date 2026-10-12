# CPU and device-card follow-up — 0.5.4 / build 27

Implemented on 2026-10-12.

## Observations

Two read-only process snapshots of the running 0.5.3/build 26 bundle showed main-app CPU at 81.1% and 66.7%; its AU helper was 3.7% in both snapshots. A three-second `sample` of the main app showed substantial SwiftUI/AppKit view update and layout activity. The audio callback stacks were mostly waiting; the engine lifecycle queue was repeatedly reading the full Core Audio catalog. These observations identify candidates for improvement, not an exact allocation of CPU cost or a sustained benchmark.

The running bundle was packaged using the debug build configuration. The new comparison bundle uses SwiftPM release optimization. The old running app was not stopped or replaced, and its audio configuration was not changed.

## Changes

- Channel count and compact sample rate sit inside the device-name column beneath the name. Both endpoint headers retain matching title areas; icons remain bounded at 42 points and cards retain equal measured heights.
- Engine telemetry has a separate observable object. Meters, delay and live diagnostic rows observe it directly at the existing 20 Hz cadence. General configuration and the settings tab container receive model notifications when delivery status/activity changes, rather than on every frame-count update. Remote status continues to read the latest snapshot.
- Healthy recovery only mutates/publishes policy when a nonzero retry stage can actually reset after 20 clean seconds. Repeated no-op mutations no longer invalidate settings.
- The half-second runtime device recheck still enumerates all device identities and rejects duplicate selected UIDs, but reads detailed capabilities only for the selected endpoints. Full discovery remains available for settings and diagnostics. UID, liveness, runtime ID, buffer, sample rate and stream-topology checks remain in place.
- Version and bundle verification expectations advance to 0.5.4/build 27.

Whole-chain AU bypass still renders the effects and sends the dry signal onward, preserving live editor feedback; bypass is not a CPU-free comparison with an empty chain.

## Checks

- Initial sandboxed release compilation failed during Apple's `dsymutil` invocation with `Operation not permitted`. The scoped build was rerun with sandbox escalation.
- Final release compilation, packaging and ad-hoc signing passed: `make sign BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-release SWIFT_BUILD_OPTIONS='--disable-sandbox --scratch-path /tmp/audiobridge-build'`, with `SWIFTPM_MODULECACHE_OVERRIDE=/tmp/audiobridge-swift-module-cache`.
- Bundle verification passed: `make verify DIST_DIR=/tmp/AudioBridge-release`. Bundle ID `cz.bytelab.audiobridge`, version 0.5.4/build 27, minimum macOS 14.0; embedded metadata matched and app/helper signatures verified.
- `git diff --check` passed.
- Automated tests, launch of the new bundle, visual acceptance and before/after audio/CPU benchmarking were not run, following the operator's deferred manual acceptance workflow.

## Comparison procedure

Quit the current app when convenient, then open `/tmp/AudioBridge-release/AudioBridge.app`. Compare the same devices, buffers and effects over several seconds with Settings both visible and closed. Note main-app and helper CPU separately. An empty chain distinguishes bridge overhead from plugin processing. The code changes and release optimization are expected to reduce avoidable work; a measured reduction has not yet been established. Phase 5 operational acceptance remains pending.
