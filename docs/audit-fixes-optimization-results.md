# Audit fixes and optimization — 0.6.5 / build 38

Implemented on 2026-10-13 from the approved [independent audit](independent-concurrency-performance-audit.md), whose source baseline was `1c2acef` (0.6.4/build 37). Three independent reviewers then inspected the relevant fixes without executing the app. Their follow-up found a missing allocation check and retained start-attempt accumulation; both were corrected before the final build and tests.

## Changes

- **Editor completion:** binary-property-list validation and the 8 MB limit operate on a candidate saved effect. Failed live saving closes/cleans up the editor and finishes the pending command exactly once with an error. Previous saved state survives; audio continues. Parameters already changed live are not rolled back.
- **Stop during preparation/start:** an irreversible, attempt-specific atomic C gate is published before queueing preparation. Stop cancels published attempts immediately, without holding the publication lock across driver calls. Preparation, HAL start and callbacks check it. Work already executing in a callback can finish. C engine ownership keeps the gate alive through teardown or deliberately retained unsafe-detach memory. Lifecycle teardown retires the Swift attempt, including automatic retries.
- **Remote lifecycle:** separate HTTP/OSC epochs reject obsolete acceptance, receive/dispatch and listener status work. Shutdown invalidates first, then cancels listeners and tracked accepted connections. Feedback callbacks/ticks are generation-checked. OSC bypass uses signed big-endian Int32, not float bit interpretation; exact tags, argument count, packet length and finite/range checks are enforced. Existing URLs, bearer authentication and source-IP allowlisting are preserved. Shared parsers/epoch logic are testable in AudioBridgeCore.
- **Runtime discovery:** watchdog scans retain UID uniqueness, liveness, current rate/buffer/topology/formats and latency, while skipping static capability lists, names and icons. Volume operations resolve the selected UID afresh and query only required properties. Setup retains full catalogs; no fallback device is introduced.
- **Routing:** preallocated active/ramping physical-channel indices avoid per-frame traversal of unpatched channels. Fade-out/reversal and summation order are preserved; output buffers are explicitly cleared. Coherent 64-bit publication versions cache unchanged targets and reject exhaustion before both-direction publication.
- **FIR demand:** callback-owned plans reuse the original demand calculation, validated by owner and resampler generation. Reset/process invalidates plans; changed ratios/recentering rebuild them. Filter arithmetic, unity filtering and short-read behavior are unchanged.
- **Worker reporting:** protocol **8** adds complete cycle and adoption metrics. Cycle time covers adoption, foreign render-context hooks and processing autorelease-pool drain, excluding idle waits. Metric recording itself follows the timed scope. Existing DSP timing remains separate. Diagnostics and Copy Status identify these as **run totals**, unaffected by Reset counters, and never add them to signal latency. English/Czech help explains the scope. Host and helper must come from the same bundle.
- **Other bounded work:** queue-only transport reads replace unnecessary full snapshots; supervision reuses one transport metrics snapshot; identical-pointer copies are skipped. Pool lifetime, wake fences, FIR and scheduling policies remain intact. SIMD and cache-line changes are deferred.

Principal source areas: AudioBridgeRealtime (gate, routing, FIR, transport), AudioBridgeEngine (lifecycle/snapshots), AudioBridgeDiscovery (runtime/volume probes), AudioBridgeAU/AUWorker (editor and cycle timing), AudioBridgeCore/RemoteControl (protocol/lifecycle), diagnostics/localization and bundle metadata. No new dependency or Xcode project.

## Automated evidence

Final `make test` completed at **2026-10-13 09:12:17 local time**: **72 XCTest tests, zero failures**, 0.534 seconds for the final suite. Swift Testing's separate discovery reports zero tests; it is not the XCTest count. Test compilation uses the existing isolated scratch workflow. Logs are retained locally under ignored `.build/audit/`.

New regression sources cover:

- OSC integer 0/1 and invalid values, float gain, malformed/truncated/trailing packets and nonfinite gain;
- stopped/restarted service generations, stale status and a partial HTTP frame completed after simulated disable;
- invalid/oversized editor state, previous-state preservation and exactly-once completion followed by a new command;
- gate cancellation and retained ownership, rejecting start before any HAL call using dummy IDs;
- cycle/adoption accounting and protocol version;
- current topology changes versus static capability/latency-only changes;
- FIR near-integer ratios, short reads, reset, owner/generation rejection and exact equivalence with the wrapper path;
- sparse planar/interleaved 2/16/256-channel routing, activation/fade-out/reversal and Off output silence against a dense ramp reference. Fan-out comparison allows 1e-6 Float rounding difference; input mix comparison is exact.

These are deterministic component tests. They do **not** exercise Network.framework sockets, real Stop/AudioDeviceStart interleavings, plugin editor windows, third-party property calls or physical device teardown.

| Command | Observed result |
|---|---|
| `make doctor` | Passed: Xcode developer directory, Apple Swift 6.4, arm64, macOS 27 SDK |
| Release `make build` | Passed; also invoked by the final `make sign` dependency chain |
| `make test SWIFT_BUILD_OPTIONS=--disable-sandbox` | 72 tests passed, zero failures |
| Release `make app` | Passed through the final sign dependency chain; bundle plist lint OK |
| Release `make sign` | Passed; final release build 20.36 seconds; host/helper ad-hoc signatures valid |
| `make verify DIST_DIR=/tmp/AudioBridge-0.6.5-final` | Passed, plist/localizations/embedded metadata and host/helper signatures |
| `make run`, live audio/API/OSC/plugin tests | **Not run**; running app left untouched |
| Distribution/notarization | **Not performed** |

Build/sign used `SWIFTPM_MODULECACHE_OVERRIDE=/tmp/audiobridge-swift-module-cache`, `BUILD_CONFIGURATION=release`, `DIST_DIR=/tmp/AudioBridge-0.6.5-final` and `SWIFT_BUILD_OPTIONS='--disable-sandbox --scratch-path /tmp/audiobridge-build'`. No SDK installation or permission reset was performed.

Bundle: `/tmp/AudioBridge-0.6.5-final/AudioBridge.app`. Verified identity: `cz.bytelab.audiobridge`, executable `AudioBridge`, version **0.6.5**, build **38**, minimum macOS **14.0**, `LSUIElement=true`, icon `AudioBridge.icns`. This is an arm64 development bundle, ad-hoc signed with no TeamIdentifier; it is not a notarized distribution artifact.

## Synthetic component comparison

`bash scripts/benchmark-processing.sh` compiles baseline `1c2acef` and current C components with Apple clang `-O3`, then runs five trials. The harness loads no HAL devices, plugins or running app. Routing uses 128-frame blocks and two active physical patches on 2/16/256-channel synthetic devices; FIR uses 32 output frames and ratio 1.0002. Routing has 1,000 iterations per trial; FIR has 10,000. Identical synthetic demand/render totals and signal checksums are reported.

| Component | Baseline median µs/block | Current median µs/block |
|---|---:|---:|
| Routing, 2 channels | 2.422 | 2.466 |
| Routing, 16 channels / 2 active | 15.996 | 2.559 |
| Routing, 256 channels / 2 active | 247.798 | 3.530 |
| FIR demand + process | 0.817 | 0.778 |

Stereo timings overlap across trials; no stereo speedup is claimed. Sparse wide-device improvements do not establish whole-app CPU savings for a mono/stereo setup. FIR savings are small. Measurements exclude IPC, HAL, plugin work and driver probes; system load was not controlled. They are neither deadline guarantees nor physical audio-quality/latency evidence.

## Review gate / checks still required

1. On this exact bundle, test Stop while preparing/starting, repeat recoverable helper failures and verify no retired-attempt growth. Driver Stop/destroy calls themselves can still block; no timeout guarantee is added.
2. Test real invalid/oversized AU state on both editor close paths, then another Edit/update. Check audio continues and the previous saved state remains. Third-party plugin property/teardown calls can still block the helper main thread.
3. Complete a partially received authenticated HTTP command after disable; verify no dispatch. Restart each service and confirm stale listener/feedback events cannot change status. Send canonical OSC integer bypass 0/1 over the LAN allowlist. Parser/epoch simulation does not replace these socket checks.
4. Validate narrow probes on actual drivers: unchanged UIDs, changed current formats/buffers/channel topology, duplicate UID rejection, latency refresh and selected output volume.
5. Compare loaded DSP off, individual plugins and full chain at the same device settings (operator preference: input 128 / output 32 / reserve 128). Observe complete-cycle/adoption timings alongside DSP and wake timing, queue bounds, drops, CPU and memory. Reset counters is an observation baseline; complete-cycle metrics remain run totals.
6. Physical loopback latency and a documented **12-hour** nominal run remain open, together with broader device loss/re-arm, sleep/wake and hardware compatibility gates. Earlier operator clean-run reports did not include a duration and do not certify this revision.

Stop for review. No claim of zero glitches, whole-app CPU reduction, deadlock freedom or unattended production readiness follows from these checks.
