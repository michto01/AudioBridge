# Review fixes and Settings focus — 0.3.8 / build 17

The user requested all four fixes: Settings focus plus the three findings from the audio-processing review. This remains a Phase 3 repair; Phase 4 and live acceptance gates are not passed.

## Implemented changes

1. Settings uses the native SwiftUI openSettings action with app activation and a weak reference captured from the actual Settings scene's AppKit window. It restores a minimized window and makes it key/front. First creation is handled by window attachment and a subsequent main-thread attempt; no title-based window matching or private selectors. Audio ownership is unchanged.
2. The PI hold predicate now requires low processed delivery **and excess conserved source backlog**. Low total occupancy continues updating the controller toward slower consumption rather than freezing an old positive correction. Existing correction/slew bounds, FIR resampling, refill reserves and manual hardware buffer settings are preserved.
3. Clock-balance occupancy is accepted capture frames minus output source frames consumed/discarded, using existing wrapping UInt32 ring counters. Worker reads/writes and in-flight publication do not change this balance. Both counters start at zero and share the same fixed-frame stereo domain. In the output callback only capture can advance during sampling. UI samples are approximate and bounded by two queue capacities plus a maximum 256-frame worker block. A helper render failure stops routing rather than pretending lost frames were delivered. Discards and FIR prefetch are naturally included in source consumption; FIR lookahead remains a separate delay allowance.
4. Running AU latency is re-read on the helper main thread at the nominal 10 Hz control poll, before its busy/editor-command check. This also covers AUv2 plugins that omit change notifications. Each report and the chain sum are checked for finite nonnegative values; invalid reports fault the helper. Only changed sums publish, without changing readiness. Queries never run in HAL callbacks or the AU render loop. Live chain replacement still publishes its initial report, then polls the new units. This updates the accounting estimate; it does not implement bypass latency matching or guarantee uninterrupted plugin oversampling changes.

Playback delay and queue range now use the conserved pending-source total. Individual capture/processed/in-flight samples remain visible as approximate diagnostics and are no longer added together for the live total. Copy status includes the conserved count. DelayEstimate retains its explicit-component fallback for callers without conserved telemetry.

## Test sources written, not executed

- Low processed availability with low/equal total backlog does not hold PI updates; excess backlog does. A synthetic low-occupancy run allows an initial +700 ppm command to move negative while retaining bounds.
- Source balance remains 64 frames before capture consumption, during rendering and after output publication while in-flight remains set. It falls only on source consumption/discard. Changed AU latency publishes without changing readiness.
- Conserved delay accounting replaces overlapping raw queue/in-flight reports; unknown device values remain unknown.

No test target was compiled or executed, no app was launched, and no plugin or live audio check was performed, per the standing user instruction.

## Manual acceptance pending

- Confirm build 17; press Settings with another app frontmost, Settings behind another window, minimized, closed, and on first creation. Confirm the correct window gets focus without affecting routing.
- Compare full Copy status and counter deltas with an empty chain, active chain and bypass. Verify pending-source counts, correction, hold counts, rebuffering and audible continuity at the same buffer settings.
- Change an installed plugin's lookahead/oversampling while its editor is open; verify reported latency follows the plugin's actual report. No guarantee is made for a plugin that fails to report its latency, blocks property reads, or requires resource reconfiguration.
- Execute deferred fake-clock, conservation and delay tests later; extend clock tests to the complete callback/worker pipeline and UInt32 wraparound. Hardware success and unattended readiness remain unverified.

## Actual checks

- `make build`: passed, final debug build complete in 3.46 s; earlier compilation also passed in 6.52 s.
- `make BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-phase2 sign`: passed; production build complete in 15.15 s, packaging/plist lint and ad-hoc helper/app signing successful.
- `make BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-phase2 verify`: passed; cz.bytelab.audiobridge, AudioBridge executable/icon, deployment 14.0, LSUIElement true, 0.3.8/build 17. Embedded metadata matches bundle; arm64 helper/app signatures valid.
- `git diff --check`: passed.
- Tests and runtime acceptance: not run. Build/signature success does not confirm Settings focus, dynamic plugin latency or improved hardware drift.
