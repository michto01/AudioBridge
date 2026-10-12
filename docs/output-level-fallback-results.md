# Output level fallback — 0.5.5 / build 28

Implemented on 2026-10-12 following the operator's requested simplification.

## Behavior

- Input trim remains available in Bridge.
- Output has one primary control: writable Core Audio device volume when supported; otherwise the existing smooth digital gain slider, labeled Digital fallback. A readable but non-writable master volume also uses the digital fallback.
- Digital gain applied to the engine is 0 dB when device volume is writable. Saved digital gain is retained as a fallback and is not silently deleted or reapplied during same-device capability refresh. Hardware volume is never changed merely by entering the new mode.
- Capability checks show Checking while pending. Manual Start waits; desired auto-resume/recovery waits for completion without treating the pending check as an action-required fault. Live gain mode changes use the existing 20 ms ramp.
- The menu continues to offer hardware device volume only. Fallback digital gain is adjusted in Bridge, preserving the earlier decision to keep digital trim sliders out of the menu.
- HTTP/OSC outputGain commands are accepted only for digital fallback. Writable-volume and pending-check modes return a rejection through the existing remote command path. Remote status distinguishes effective outputGainDB from saved outputFallbackGainDB and reports outputLevelControl. Copy Status distinguishes applied and saved gain as well.

## Audio limits

Code inspection found that existing digital gain uses a 20 ms sample ramp. It does not establish digital gain as the cause of reported audible artifacts. Holding gain at unity removes an unnecessary operator adjustment in device-volume mode; no repair of audible artifacts is claimed. Software output meters are upstream of device volume. Effects or input mixing can still exceed full scale even when output gain is unity; device volume is not a substitute for managing that signal level.

A previously saved nonzero output gain is no longer applied on devices with writable volume. That can change playback loudness compared with the previous build. The device's existing volume is retained; the operator should confirm the level on the first run.

## Acceptance

- Release build, bundle packaging and ad-hoc signing passed: `make sign BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-release SWIFT_BUILD_OPTIONS='--disable-sandbox --scratch-path /tmp/audiobridge-build'`, with `SWIFTPM_MODULECACHE_OVERRIDE=/tmp/audiobridge-swift-module-cache`.
- Bundle verification passed: `make verify DIST_DIR=/tmp/AudioBridge-release`. Version 0.5.5/build 28, bundle ID `cz.bytelab.audiobridge`, minimum macOS 14.0; app/helper signatures verified and embedded metadata matched.
- `git diff --check` passed.
- Automated tests, launching the new bundle, audio/visual acceptance and remote command checks were not run, following deferred manual acceptance.

Manual review: writable built-in speaker volume; an interface without writable master volume; retained nonzero fallback gain; same-device refresh while running; changed output selection; auto-resume while capabilities load; remote fallback acceptance/rejection; and output meter versus physical-volume behavior. Phase 5 operational acceptance remains pending.
