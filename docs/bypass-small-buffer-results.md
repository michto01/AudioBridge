# Editable bypass and smaller bridge buffers — 2026-10-11

User confirmed the prior slice otherwise working, reported odd bypass behavior in plugin interfaces, and requested continued editing with bypass indication. They asked whether 16/32/zero buffers are possible. Version 0.2.6/build 7 addresses this slice; runtime checks remain deferred.

## Bypass behavior

Bypass now chooses the preserved dry input for output while still rendering the effects. Their editors, meters and DSP histories continue receiving processing calls; no host bypass flag disables their controls. A visible orange "Chain bypassed" notice appears in live and stopped plugin windows. Live windows poll the shared bypass flag; stopped windows receive the current state in a private configuration file and update when the main button changes. Trim and gain remain active; bypass retains plugin CPU cost and plugin failures can still stop routing. Inactive individual slots remain distinct from whole-chain bypass.

## Buffer limits

256 was the helper's fixed block size, not a claimed hardware minimum. Startup fill now allows `max(16, input current buffer, output current buffer)` through 32768 frames. AU blocks use the largest power of two no greater than startup fill, between 16 and 256. Helper waiting scales with block duration (50–1000 microseconds), outside HAL callbacks. Presets remain conservative; exact Expert/slider settings expose smaller values when devices permit them.

To use a 16-frame bridge target, both device buffers must first be set to 16 or less through their driver-supported interface controls. For 32 frames, both must be 32 or less. Driver ranges and actual accepted values determine availability; no automatic hardware change. A plugin may reject the requested processing format/resources, in which case routing reports failure.

Zero hardware or bridge buffers are not supported. This path uses nonempty device callbacks and asynchronous shared queues; no zero-latency claim. At 48 kHz, 16/32/256 frames are about 0.33/0.67/5.33 ms of sample duration, **not** measured total latency. Smaller settings increase scheduling/underrun risk. No promise that 16 frames is reliable on this Mac or with installed plugins. Keep a stable larger preset for deployment until measured checks and remaining drift/recovery work are complete.

## Evidence and deferred checks

`make build` passed (2.18 seconds) after behavior changes. Final `make DIST_DIR=/tmp/AudioBridge-phase2 sign` rebuilt successfully (2.52 seconds), packaged and signed. `make DIST_DIR=/tmp/AudioBridge-phase2 verify` passed: `cz.bytelab.audiobridge`, 0.2.6/build 7, macOS minimum 14.0, icon present, strict helper/deep app ad-hoc signatures valid (arm64). `git diff --check` passed. Unit test source covers 16/32/48/128/512 frame block selection and zero/out-of-range rejection; not compiled or run.

No app launch, hardware buffer write, plugin instantiation, audio test or automated test executed. Deferred acceptance: edit parameters with bypass active; toggle bypass while editor remains open; confirm indication and dry/wet routing; save/reopen while bypassed; verify 16/32 buffer readback, callbacks and underruns across representative plugins/devices; measure CPU and end-to-end latency. Unattended phase gates remain pending.
