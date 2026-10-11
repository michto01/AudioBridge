# Interface buffers and AU editor correction — 2026-10-11

Build 0.2.4 (5), user-requested follow-up. Runtime and automated tests remain deferred.

## Changes

- Audio endpoint settings now expose a compact interface-buffer slider and exact frame entry with Apply, only when Core Audio reports the device-global buffer property writable and a valid range. Read-only/unavailable drivers show an explanation. Bridge FIFO controls remain separate.
- Apply requires routing and the editor stopped. Discovery resolves the explicit UID afresh, validates liveness/range/writability and UID before setting `kAudioDevicePropertyBufferFrameSize`, then reads back the accepted value and refreshes the catalog. No default substitution, automatic launch-time reapplication or sample-rate change. A device may round, defer or reject a request; status displays actual readback or HAL error. A device-wide change may affect other apps using that device.
- The original editor supported only `AUAudioUnit.requestViewController`; it omitted the legacy AUv2 `kAudioUnitProperty_CocoaUI` factory. An ARC Objective-C shim now loads the advertised bundle/class, invokes `AUCocoaUIBase`, releases returned property references, and hosts the view with scrolling. The helper retains the AVAudioUnit wrapper and edits the same unit whose state is saved.
- AUv3 view controllers and generic parameters remain available. Editor gets an explicit content area and regular application activation so it can be found independently. Adding an effect opens its editor automatically; Edit reopens it. Rendering and HAL callback behavior are unchanged.
- User identified "Tokio Nova". Read-only installed bundle inspection confirmed Tokyo Dawn Labs TDR Nova 2.1.6, an AUv2 `aufx` component (`Tdrl`/`Td5a`). It was not instantiated. The omitted AUv2 UI path is relevant, but the exact window symptom and successful UI rendering remain unverified.

## Checks and remaining acceptance

Initial build failed on the missing explicit `AUCocoaUIView.h` import. Corrected the import, enabled ARC and removed a nullability warning. `make build` then passed (1.79 seconds). `make DIST_DIR=/tmp/AudioBridge-phase2 sign` rebuilt the final changes (1.86 seconds), packaged and signed successfully. `make DIST_DIR=/tmp/AudioBridge-phase2 verify` passed: bundle `cz.bytelab.audiobridge`, version 0.2.4/build 5, minimum macOS 14.0, icon present, strict helper and deep app ad-hoc signatures valid (arm64). `git diff --check` passed.

No automated tests, real buffer writes, plugin instantiation, editor visual check or live audio check were run. Deferred manual checks: writable/read-only drivers; accepted/rounded/rejected requests; actual next-run callback sizes; selection/disconnect race handling; AUv2 and AUv3 editor appearance, oversized editor scrolling, Save/reopen state and Cancel. These are acceptance checks, not passed tests. Existing unattended prerequisites and phase gates remain pending.
