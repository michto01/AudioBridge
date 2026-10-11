# Compact buffers and gain — 2026-10-11

## User evidence and scope

The user reported that microphone routing works after removing/re-enabling AudioBridge's microphone permission. This is user-reported microphone routing, not automated hardware validation, stereo isolation, extended drift testing or complete Phase 2 acceptance. They requested smaller buffer controls with a range slider and Expert entry, input/output gain, and an assessment of AU/VST hosting. This slice implements buffer UX and digital gain; plugin hosting remains a proposal.

## Implementation

- Compact logarithmic buffer slider, displayed frame range/value and startup duration. Expert expands exact integer entry plus Low/Balanced/Robust preset selection. Editing requires Stop. Old preset preference migrates naturally: no custom value means the existing preset calculation still applies.
- Custom bridge startup fill is saved as `AudioBridge.bufferFrames`; it must be at least the larger selected device callback buffer and at most 32768 frames. The UI minimum is at least 16 frames. A custom target invalidated by a later device selection is retained and Start explains the necessary correction. Slider steps select powers of two (bounded by the actual minimum); exact entry need not use a power of two.
- Ring capacity is now automatically the next power of two at or above max(1024, 2 × target, 4 × device buffer), up to 65536 for supported device buffers. This replaces a fixed minimum capacity of 16384. Capacity is distinct from startup-fill latency; neither is measured end-to-end latency. HAL buffer sizes remain read-only and drift compensation is still pending.
- Input trim and output gain: linked across the two logical lanes, −60 to +12 dB, 0 dB defaults, exact dB entry/reset and slider. Separate preferences survive relaunch. Updates can occur live; amplitude targets are sent on the lifecycle queue into lock-free atomic integer bits. Per-direction callback-owned ramps change linearly over 20 ms at the actual sample rate, beginning at the current amplitude on retarget. Initial configured gains are set before callback registration.
- Processing order: capture → finite-sample validation/raw full-scale counts → input trim → input meters → FIFO → output gain → physical output summation if explicitly duplicated → output meters → HAL. No hidden limiter or normalization. Full-scale counts are not proof of analog clipping; attenuation cannot repair samples already clipped during capture.
- Pure C gain functions are bounded, allocation-free and use no logging, UI or locks. Gain target stores are the only cross-thread gain state; current ramp values belong exclusively to the respective callbacks. Context updates/teardown stay serialized.
- Version 0.2.2/build 3. Permission UI reports authorization without asserting capture validation.

## Permission investigation

`codesign -d -r- /tmp/AudioBridge-phase2/AudioBridge.app` showed `designated => cdhash ...` for the prior ad-hoc build. Rebuilds change that identity hash, a plausible explanation for stale TCC authorization. The user workaround is documented; the exact TCC failure mechanism has not been independently verified. No automatic TCC reset, new certificates, weakened designated requirement or production installation was introduced. Stable development signing can be considered separately if this remains disruptive.

## Plugin hosting assessment

For this macOS-only app, **AU first** is the recommended engineering direction: Apple provides instantiation, render interfaces and component APIs through AudioToolbox. The installed SDK declares `kAudioUnitSubType_DynamicsProcessor` and `kAudioUnitSubType_PeakLimiter`, so a tightly scoped Apple-component chain could reuse compression/limiting without implementing those algorithms. Availability/behavior still needs runtime validation.

General third-party hosting adds discovery/validation, bus-format negotiation, bounded render buffers, parameter/editor UI, state/preset persistence, reported latency/tails, bypass semantics and a failure/isolation policy. Arbitrary plugin code cannot simply inherit our callback safety guarantee. Plugin hosting is a separate substantial slice; start with one AU effect before promising arbitrary chains. VST3 additionally needs Steinberg's SDK and a native hosting adapter. No dependency was added here.

This is an assessment, not approval to expand the locked v1 scope: compression/limiting and extra DSP are explicitly out of scope in `overview.md`. Adding AU effects would require revising that scope and an explicit future implementation request. My recommendation is to complete drift/recovery first, then implement an optional AU effect slot as a separate milestone if desired.

Primary references: [Apple AUAudioUnit](https://developer.apple.com/documentation/audiotoolbox/auaudiounit), [Steinberg VST3 SDK](https://github.com/steinbergmedia/vst3sdk). Installed SDK evidence: AudioToolbox `AUComponent.h` declares dynamics/peak limiter component subtypes. No plugin was instantiated or tested.

## Actual checks and deferred tests

- `make build`: passed (`Build complete! (2,48 sec)`).
- `make DIST_DIR=/tmp/AudioBridge-phase2 sign`: passed; final rebuild `Build complete! (1,50 sec)`, plist lint and ad-hoc signature verification successful.
- `make DIST_DIR=/tmp/AudioBridge-phase2 verify`: passed; `cz.bytelab.audiobridge`, `AudioBridge`, minimum macOS 14.0, version 0.2.2/build 3, icon `AudioBridge.icns`, valid strict arm64 ad-hoc signature.
- Current bundle registration refresh (`lsregister -f`): passed, no app launch or permission reset.
- Written `GainTests`: dB conversion, finite bounds, exact ramp target, mid-ramp retarget, invalid targets. Existing FIFO/meter tests retained. **No tests were executed or compiled**, per user instruction.
- No app launch, HAL start/stop, gain listening test, plugin instantiation or actual device buffer modification in this slice.

Deferred manual checks: reopen 0.2.2, confirm saved routing and permission, set a small valid buffer (with 512-frame devices, 512 is the initial minimum), route at low system volume, adjust input trim/output gain, confirm meters respond and Stop works. Restart to check persistence; set an Expert target and change devices to check validation. Later execute unit tests, race checks and drift/soak acceptance before unattended use.
