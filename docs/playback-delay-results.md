# Playback, Effects and delay accounting — 2026-10-11

Version 0.3.4/build 13, optimized release. Phase 3 follow-up; no supervisor/recovery/login implementation.

## User evidence

Build 12: built-in microphone/speakers, 48 kHz, 512-frame device buffers and startup fill, SSQ → EverClean → COMPER, about 326 seconds captured. Fresh callbacks, 386 underrun frames, no overruns, three rebuffers, no recentering, command approximately −0.007 ppm. This is markedly fewer interruptions than the earlier 32-frame report, but not a continuous-audio or unattended acceptance pass. Amber remains latched by cumulative delivery faults for the run. Physical full-scale count 1730 is signal-level information, not a glitch counter.

## UI and buffer drafts

- Playback (play icon): Start/Stop, status/reason, endpoint names, linked trim/gain, Mix L/R meters, Copy status, delay summary/breakdown and processing counters. Start/Stop removed from Audio and Routing; menu-bar quick controls retained.
- Effects: installed AU catalog, ordered chain and editor controls moved out of Audio.
- Audio: devices/driver buffers, bridge fill and microphone permission. Routing: patch grids and live cell gains.
- Buffer control initializes from actual `device.bufferFrames` and tracks read-back changes, including custom values. Unknown current value uses a 128-frame draft within a valid reported range. 64 and 128 already belong to the common dropdown, filtered by reported capability range. Unchanged values disable Apply. No automatic hardware write, power-of-two guarantee, change of saved bridge fill, or system-default substitution.
- A real current value of 512 remains selected. The user must Stop and explicitly Apply a different value. The old selector also normally read current values on appearance; its 512 fallback is removed, not evidence that the earlier hardware values were set by the host automatically.

## Delay and performance telemetry

Read-only catalog adds optional direction-scoped device latency and safety offset, plus stream latency. Old diagnostic payloads decode missing optional fields as nil. Probe errors remain visible; missing values are not zero. All HAL queries occur outside audio callbacks.

The accounting model sums input/output reported device latency, maximum latency among explicitly routed streams per direction, safety offsets, one current callback buffer allowance per direction, observed capture queue, processed queue, in-flight AU block, FIR lookahead allowance and AU declared signal latency. Bypassed chain contributes zero AU signal latency while still rendering plugins. Unrouted streams are excluded. The sum is labelled **Estimated chain allowance**, or **Known subtotal · incomplete** if reports are missing. Startup fill is a target, not additional queued audio, and is not added again. One callback buffer per direction is a scheduling allowance; this is not timestamp-correlated sample transit, physical loopback measurement, or a guaranteed bound. Driver/plugin reports (including zero) can omit real internal/downstream delays.

Snapshots retain the run's selected devices/physical patches/bypass state, so stopping and editing future selection does not relabel last-run delay accounting. Reported latency updates do not invalidate routing topology. The existing periodic fresh device check updates latency facts and now explicitly detects hardware buffer changes against the prepared plan; topology/rate/UID changes still stop without fallback.

Shared transport ABI is version 3 for added counters: in-flight frames, timed blocks, total/last/max wall processing nanoseconds. A single helper worker sets in-flight before reading a block and clears it on all processing exits; `mach_absolute_time` and a timebase cached at mapping setup measure the block outside HAL callbacks. Timed scope includes queue read/write, deinterleaving, AU processing, validation and scheduling/preemption; excludes idle sleep. Failed attempted blocks are also timed. Wall time is **not** CPU utilization and is **not added** to the signal latency accounting. AU block duration in frames/ms is shown for comparison. Whole-chain bypass retains DSP cost.

Capture/processed/in-flight counts and wall counters are independent atomic reads, not a coherent tagged-sample snapshot; estimates can vary by a processing block near a transition. Primed queue+in-flight min/max is sampled at 20 Hz and reset on Start, not an exhaustive high-frequency extremum. No logging, allocation, HAL calls, locks or clock queries are added to the HAL callbacks. Existing lock-free checks cover new shared counters; main/helper ABI mismatch is rejected.

SDK evidence: installed macOS 27 `AudioHardwareBase.h` documents input/output device latency, additional stream latency summed with device latency, and safety-offset frame semantics. `mach_time.h` supplies monotonic absolute timing/timebase conversion. This source review does not verify any particular driver's reported values or physical delay.

## Actual evidence

Initial debug build failed because frame-range rounding used ceil/floor without an import; replaced with standard `rounded(.up/.down)`. Debug rebuild passed, 4.32 seconds. Final `make BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-phase2 sign` passed: production build 15.10 seconds, packaging/plist lint, helper/app ad-hoc signatures. `make DIST_DIR=/tmp/AudioBridge-phase2 verify` passed: identifier `cz.bytelab.audiobridge`, executable AudioBridge, minimum 14.0, LSUIElement true, 0.3.4/build 13, AudioBridge.icns, embedded metadata matches bundle, valid helper/app signatures, arm64. `git diff --check` passed.

New `DelayEstimateTests.swift` covers component arithmetic, routed stream filtering, bypass, unknown/invalid reports, current/custom buffer draft preservation and fallback, topology ignoring latency-only changes, and shared helper timing publication. These sources were **not compiled or run**. No automated app launch, audio, plugin execution, screenshots, CPU profiling or loopback measurement was run. COMPER needle behavior remains unverified; no change here claims to repair it.

## Written manual acceptance (not executed)

1. Quit old instance, reopen `/tmp/AudioBridge-phase2/AudioBridge.app`, confirm build 13. Review Playback play icon, Start/Stop/reasons, meters/trim; Audio device/buffer/permission controls; Routing grids; Effects chain/editing. Check narrow plugin editors, keyboard/VoiceOver and tab widths.
2. Confirm hardware drafts equal current 512 (or driver value). Stop, explicitly apply 64/128 if supported, inspect accepted read-back, then choose a bridge fill satisfying the new device minimum. Confirm no automatic hardware changes on tab selection/relaunch; custom and read-only drivers remain usable.
3. Start, inspect frame/ms components, queue range, AU wall last/mean/max and timed count. Copy status, stop, change future selection; last-run delay must still name its actual device/patch facts. Repeat Start to reset extrema.
4. Compare empty chain, plugins, dry bypass and live replacement with identical route/buffers. Verify reported plugin latency and in-flight counters; zero declared plugin latency must not be mistaken for measured zero. Compare processing max to block duration and delivery faults, without equating wall time to CPU.
5. Measure true end-to-end delay later with a stated physical loopback/reference and compare to accounting allowances. Validate missing latency properties, multistream fan-out (maximum routed latency), driver changes, teardown and long duration. Independently sampled queues may fluctuate; do not claim sub-frame transit accuracy.

Changed files: Playback view; Audio settings/control placement and Copy status; device/buffer/delay core facts/model; discovery; engine/host snapshot fields; C AU transport and worker timing; deferred tests; README/design/plan; bundle version and verify script; this result document. Stop for review before Phase 4. macOS 14/Intel runtime, actual delay/CPU, COMPER meters and unattended readiness remain pending.
