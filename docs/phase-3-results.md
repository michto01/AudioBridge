# Phase 3 adaptive drift and matrix implementation — 2026-10-11

User authorized the next phase after the AU/UI follow-ups and confirmed Git workflow should continue. Version 0.3.0/build 9 implements the remaining Phase 3 processing slice. Automated and hardware acceptance remains deferred under the standing instruction; this is not a passed Phase 3 gate.

## Processing

Input trim → AU chain (or explicit dry bypass) → adaptive FIR resampler → 2×2 matrix → output gain → selected physical outputs. Equal nominal device sample rates are still required. This slice corrects small clock differences; it does not enable arbitrary nominal-rate conversion, integer PCM, multiple streams or same-device duplex.

The C output callback owns a preallocated 32-tap/256-phase Blackman-windowed sinc resampler. Coefficients are computed before HAL registration, normalized for DC with provisional 0.95 Nyquist cutoff. Fractional ratio changes alter actual source-frame consumption, so this is resampling rather than a FIFO-only drift claim. It adds a 17-frame prefetch (16-frame future span); priming waits for startup fill plus this prefetch. It filters even at unity ratio and is not bit-perfect. Filter response, near-Nyquist loss, transition artifacts and CPU cost require measurement.

The controller observes combined AU input/output queue occupancy, accounting for the helper's asynchronous transport. Target is startup fill + 17 + half the current input callback buffer. A two-second occupancy filter feeds a PI controller; correction is bounded ±1000 ppm with ±50 ppm/second slew and bounded integral ±800 ppm. These are provisional tuning constants, not measured clock facts. Correction shown in Diagnostics is commanded consumption adjustment, not an independent clock-frequency measurement. Driver burst timing, worker scheduling, tiny buffers and plugin stalls require simulation/hardware validation.

Starvation produces zeros for unfilled output and forces re-priming, with rebuffer events and subsequent waiting silence counted. Near-full output queues discard excess output toward startup fill plus prefetch, reset filter history and count discarded frames. Such recentering is an audible discontinuity, not seamless correction. Resampler-history loss at reset is not included in the queue-discard counter. Capture-ring overflow remains counted separately. No silence notification or endpoint substitution.

Device selectors and meters now use In 1 / In 2 and Out 1 / Out 2 labels matching the matrix. Physical channel selection remains explicit and separate from mixing.

Matrix coefficients are persisted linear amplitudes in 0–1, identity by default. Presets: stereo, swap, 0.5+0.5 mono, input 1 to both. Live changes use 20 ms ramps. Atomic coefficient publication uses a bounded version check; an overlapping write waits until a later callback rather than spinning. Initial matrix is installed before capture starts. Summing can exceed full scale; no hidden normalization/limiter added. Corrupt saved matrix blocks routing and retains data.

## Callback ownership

No Swift/UI/plugin call, heap allocation, lock, await, property query or synchronous log was added to HAL callbacks. FIR state/coefficients and scratch storage are allocated before registration and freed only after callbacks detach. Controller and matrix ramps belong exclusively to output callback; lifecycle reads only atomically published metrics. Teardown failure retains the complete context as before. This is a source-level audit, not sanitizer/runtime proof.

## Actual checks

`make build` passed (3.89 seconds) for initial Phase 3 code. Final `make DIST_DIR=/tmp/AudioBridge-phase2 sign` passed, including build (2.77 seconds), packaging and ad-hoc signing of app/helper. `make DIST_DIR=/tmp/AudioBridge-phase2 verify` passed: bundle identifier `cz.bytelab.audiobridge`, executable `AudioBridge`, minimum macOS 14.0, menu-bar mode, version 0.3.0/build 9, `AudioBridge.icns`, byte-identical embedded/bundle Info.plist and valid app/helper signatures. `git diff --check` passed. The `/tmp` destination preserves the existing workaround for File Provider signature metadata. Microphone privacy icon appearance remains a manual check. `AdaptiveDSPTests.swift` contains unrun ±50/100/200 ppm long-run controller simulations, resampler DC/lane isolation/starvation and matrix preset/validation cases. Test sources are **not compiled or run**. Existing gain/FIFO tests also remain deferred.

No app launch, HAL start, plugin execution, clock simulation execution, audio-quality test or 1–2 hour hardware test performed. User's prior manual audio observations do not establish this new path's acceptance.

## Gate and next prerequisites

Run deterministic controller/resampler/matrix tests, add callback jitter and extreme queue transients, verify FIR frequency response/aliasing and matrix smoothing/coherent updates. Then perform stereo lane signal checks, low-buffer latency/CPU/underrun measurements and 1–2 hour independent-device occupancy test. Record devices, duration, actual correction, glitches, resets and audible transitions.

Stop here for review before Phase 4 desired/observed supervisor, bounded indefinite recovery and login registration. Stable installation/signing path, permission failure classification and retained manual Stop remain prerequisites. This implementation does not make the app validated for unattended streaming.
