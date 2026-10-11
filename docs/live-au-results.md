# Live AU changes, editor sizing and shared-memory follow-up

2026-10-11, version 0.2.5/build 6. User reported small SSQ (Analog Obsession) editor windows, requested live propagation/inserts and whole-chain bypass, and reported "cannot allocate AU shared memory". Automated/runtime checks remain deferred.

## Implemented slice

- Editor windows use plugin frame/fitting size (AUv3 preferred size when available), clamp to the current display, and observe legacy view frame changes. Legacy factories receive zero preferred size to choose their native dimensions. Oversized legacy views scroll. This addresses concrete sizing omissions; SSQ's actual window behavior remains unverified.
- Running editor is hosted inside the render helper and retains the same AVAudioUnit instance used by the renderer. Parameter controls act immediately. Closing saves state back to the app without terminating the helper. Stopped editing remains a separate Save/Cancel instance. Close before Stop to preserve the latest state; live Cancel/undo is not implemented.
- Live chain commands use atomically replaced, private temporary JSON files containing configuration/state, never audio. One chain/editor command at a time. The worker prepares replacement resources asynchronously while the old renderer continues, then exchanges the renderer between 256-frame blocks. The helper-only NSLock/ARC work stays outside HAL callbacks. Previous resources remain retained through their final block. The app/HAL do not restart; tails/history are reset and transitions may click or change latency. No seamless-transition claim.
- Whole-chain Bypass/Enable is a shared lock-free atomic flag, read between processing blocks, including while an editor is open. All effects are skipped; trim/gain stay active. Plugin state/resources remain loaded. This is an explicit user command, not a failure fallback. It persists separately from individual slot enable flags.
- The helper is now prepared for every route, including an empty chain, so an effect can be inserted later. Startup fill requires at least 256 frames. A missing, failed, stalled or timed-out chain stops routing. No automatic endpoint substitution or silent effect bypass.

## Allocation failure

The transport required `fstat` size to equal the C structure's byte count. It now allocates whole pages and accepts lengths between the logical structure size and that page-rounded allocation, supporting rounded shared-memory sizes. Each failure records its operation and errno, including mapping/lock-free validation; the parent reports this detail. This is a concrete robustness fix and a candidate explanation, **not a reproduced diagnosis of the user's failure**. If the failure persists, its new detailed message is required. Restart the old app before using the new helper: shared protocol version is now 2.

## Validation

`make build` passed after live-path implementation (2.99 seconds). Packaging/signing rebuilt successfully (2.46 seconds), then again after final editor sizing and AppKit event-loop changes (1.80 and 1.56 seconds). `make DIST_DIR=/tmp/AudioBridge-phase2 verify` passed: `cz.bytelab.audiobridge`, 0.2.5/build 6, minimum macOS 14.0, icon present, strict helper and deep app ad-hoc signatures valid (arm64). `git diff --check` passed. Test source extends `AUChainTests` with command identity, bypass encoding and shared atomic bypass visibility. Tests are **not compiled or run**.

No plugin was instantiated, no app was launched, no live signal or shared-memory runtime probe was performed. Deferred acceptance: SSQ natural size and resize behavior; live audible parameter changes; saved state after close/relaunch; inserting from an empty chain; reorder/remove/history transitions; chain bypass with editor open; repeated inserts and Stop during preparation; missing/crashing/hanging plugin; shared allocation on target Mac. Check memory/resource retirement and counters under prolonged load.

Unattended use still requires drift compensation, supervisor/recovery/login, broader PCM/device support, callback/resource audits and soak validation. This slice does not pass those phase gates.
