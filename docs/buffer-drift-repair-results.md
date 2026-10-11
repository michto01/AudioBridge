# Buffer and drift repair — 0.3.6 / build 15

## Evidence and scope

User reports drift command over 700 ppm and 3030 underruns with effects bypassed. A complete snapshot from that run was not supplied. Bypass keeps AU effects processing and selects dry output; it does not eliminate their CPU or scheduling cost. Commanded ppm is the occupancy controller output, not an independent clock measurement.

Source audit found the resampler reading the next input frame after producing the final requested output frame. An empty source then set starvation despite a complete callback, causing unnecessary rebuffering and FIR history resets. This is a demonstrated code defect; current hardware causality and improvement are not verified.

## Changes

- Advance/read source only when another requested output frame needs it. Exact demand query follows the same fractional phase operations as rendering.
- Preserve FIR history, phase and partial prime progress across empty reads. Missing output remains zero; audio is not fabricated.
- Prime/reprime only when processed source contains exact callback demand plus configured queue reserve. At unity a fresh 32-frame callback needs 48 source frames; with a 64-frame reserve the initial threshold is 112 frames. Retained history makes later demand 32 frames. This reserve adds real queue delay; Playback accounts sampled queues rather than adding it twice.
- Clock balance includes capture, processed and in-flight AU frames. Target includes reserve, one output callback and half an input callback. Hold PI updates under processed-queue pressure rather than interpreting delayed worker delivery as positive clock skew. Reanchor filtered error/integral after refilling or discarding; correction remains bounded and continuous.
- If positive correction needs an extra frame unavailable in the snapshot but unity can render the callback, apply unity for that callback. Diagnostics ppm remains the PI command, not a measured or exact per-callback applied correction.
- Bound queue discard reads to allocated scratch capacity, including when AU shared queues have accumulated beyond local scratch capacity.
- Select AU block size from the smaller of reserve and largest device callback buffer, retaining 16–256 power-of-two limits. A 32-frame device buffer and 64-frame reserve now use 32-frame AU blocks instead of 64.
- Label the setting Queue reserve and explain refill demand. Saved values and hardware buffer settings are preserved.

## Actual checks

- `make build`: passed, debug build complete in 4.00 s.
- `make BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-phase2 sign`: passed, final production build complete in 13.81 s; package/plist and helper/app ad-hoc signatures valid.
- `make BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-phase2 verify`: passed, macOS 14.0 minimum, cz.bytelab.audiobridge, AudioBridge executable/icon, version 0.3.6/build 15, embedded metadata equals bundle metadata, arm64 helper/app signatures valid.
- `git diff --check`: passed.
- Tests were written, not executed. No app launch, plugin execution or live audio check was performed, per standing user instruction.

## Deferred acceptance and limits

New test sources cover exact empty-queue callback boundaries, retained DC history after starvation, and demand/consumption agreement across 0.999/1/1.001 ratios. Existing fake-clock convergence tests remain pending, as do HAL integration and callback lifetime tests.

Manual acceptance: quit the old app and reopen /tmp/AudioBridge-phase2/AudioBridge.app; confirm build 15. Compare cumulative-counter deltas over equal intervals, queue occupancy, rebuffer count and drift command with an empty chain first, then active effects and bypass. Capture full Copy status from each run. Check clean recent status after 20 seconds, audible continuity and sustained positive/negative clock balance. No unattended-readiness claim or Phase 4 advancement.

A 64-frame reserve at 48 kHz is 1.33 ms and cannot cover arbitrary worker scheduling stalls. An earlier AU wall-time snapshot peaked around 4.93 ms; it included scheduling/preemption and is not proof of DSP CPU cost. Smaller blocks can increase plugin call overhead. This patch does not configure an audio workgroup, establish deadline guarantees, automatically increase reserve or promise all effects work at 32 frames. Sustained stalls need separate scheduling/plugin evidence and tuning.
