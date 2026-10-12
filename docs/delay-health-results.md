# Delay interpretation and recent-glitch warning — 2026-10-11

Version 0.3.5/build 14, optimized release. Phase 3 follow-up only.

## User screenshot evidence

User initially described approximately 57 ms with 32-frame device buffers and 64-frame startup fill. Supplied screenshot displays **53.44 ms** with these current terms at 48 kHz:

| Terms | Frames | Milliseconds |
| --- | ---: | ---: |
| Input stream report | 1439 | 29.98 |
| Input device report / safety | 0 + 74 | 1.54 |
| Output stream report | 690 | 14.38 |
| Output device report / safety | 70 + 74 | 3.00 |
| Device-reported subtotal | 2347 | 48.90 |
| Two callback buffer allowances | 32 + 32 | 1.33 |
| Capture + processed queues, in-flight | 32 + 105 + 0 | 2.85 |
| FIR lookahead allowance | 17 | 0.35 |
| Declared AU signal latency | 0 | 0.00 |
| Bridge + callback-buffer subtotal | 218 | 4.54 |
| Combined accounting estimate | 2565 | 53.44 |

The previous arithmetic is consistent with those reported inputs; the headline obscured the distinction between controllable bridge buffering and device reports. 32-frame callbacks and a 64-frame queue target alone do not account for all terms. At 48 kHz, nominal 32+32+64+17 frames is only about 3.02 ms, excluding device/stream/safety and any other queue or declared AU latency. Actual observed queues may differ from startup target. Do not hide the 1439/690-frame stream reports to meet a desired latency target.

Screenshot's AU block wall mean 0.22 ms and maximum 4.93 ms are processing/scheduling observations, not additional signal latency or proof of a plugin defect. Source inspection of Apple's SDK established device and stream latency are additive; it does not establish these driver values equal physical delay. No loopback, device reconfiguration, audio execution or measurement was performed by automation.

## Changes

- Delay components have explicit device-reported, callback-buffer or bridge categories. Playback's primary value shows bridge+callback buffering, followed by device-reported subtotal and combined accounting estimate. Copy status includes the split. Missing properties remain unknown; hardware/stream reports are retained, and the combined sum is unchanged. AU signal latency remains in the bridge estimate; wall processing time stays separate. This does not guarantee an end-to-end result below 10 ms.
- A deterministic `RecentGlitches` tracker runs on the existing lifecycle queue using monotonic system uptime. New underrun/overrun/format-fault deltas set a recent warning; queue recentering and rebuffer bookkeeping alone do not. Callback gaps after previously healthy delivery also require a healthy window. Startup by itself is not a glitch. Five continuous observed healthy seconds clear only the warning. Diagnostics reports the changed counter and delta, or the callback path that stopped arriving. New loss or unhealthy delivery resets that window. Faults requiring action still stop/report errors and cannot be cleared by this timer.
- Health uses fresh callbacks, priming and delivered frames. A momentarily zero processed queue is not sufficient to declare a glitch: queues can be empty between writes and the FIR retains working samples; actual starvation/rebuffer counters and priming remain authoritative. Silence and clipping do not enter this tracker.
- Status text/menu colour use recent health. Bridge shows the current reason and 0–5 s recovery progress; Diagnostics and Copy status retain the reason and healthy seconds. Counters remain cumulative throughout the run and are not erased or altered. No flushing of audio buffers, restart, supervisor, retry or notification is introduced.
- `RecentGlitchesTests.swift` covers startup, the warning recovery boundary, historical counts, renewed glitches, callback/priming gaps and recentering. Screenshot arithmetic regression is added to `DelayEstimateTests.swift`. Tests are **written, not compiled or run**.

## Actual checks

`make build` passed (4.76 seconds). `make BUILD_CONFIGURATION=release DIST_DIR=/tmp/AudioBridge-phase2 sign` passed (production build 15.72 seconds, packaging/plist lint and helper/app ad-hoc signatures). `make DIST_DIR=/tmp/AudioBridge-phase2 verify` passed: `cz.bytelab.audiobridge`, executable AudioBridge, minimum 14.0, LSUIElement true, 0.3.5/build 14, AudioBridge.icns, matching embedded/bundle metadata, valid helper/app signatures, arm64. `git diff --check` passed. No automated test execution, app launch, plugin execution, audio, profiling or hardware verification. Screenshot inspection is user evidence, not a reproduced hardware test.

## Deferred manual review

Quit old instance and reopen `/tmp/AudioBridge-phase2/AudioBridge.app`. Confirm build 14 and the separated subtotals against Copy status. After a real delivery glitch, observe amber/progress until 20 s of fresh primed delivery, then green with historical counters still visible. Confirm new faults restart progress, silence/clipping do not, unprimed/stalled output never clears, and manual Stop still wins. Verify missing latency reports and physical loopback separately. COMPER needle behavior, CPU, long-duration drift and unattended acceptance remain pending. Stop before Phase 4.

Changed: core delay categories and recent-health tracker; engine snapshot/health integration; status/menu/Playback/Copy status; deferred tests; README/design; bundle version/verify; this document.
